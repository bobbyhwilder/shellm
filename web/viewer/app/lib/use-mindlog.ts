import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";

import { fetchMindlog, pollWhileLive } from "~/lib/api";
import type { Mindlog, RunGroup } from "~/lib/types";

/** First load ships only the newest steps — a grown mind log (20k+ steps,
 * full raw payloads) is hundreds of MB whole. Older history loads in
 * chunks on demand.
 *
 * iPhone Safari/Brave OOMs mounting ~1000 StepCards (no virtualizer;
 * content-visibility is unreliable on iOS). Desktop keeps the large
 * window; coarse+narrow or iOS gets a small first paint / older chunk. */
const DESKTOP_INITIAL_TAIL = 1000;
const MOBILE_INITIAL_TAIL = 80;
const DESKTOP_OLDER_CHUNK = 2000;
const MOBILE_OLDER_CHUNK = 200;

function isCoarseMobile(): boolean {
  if (typeof window === "undefined" || typeof navigator === "undefined") {
    // SSR / unknown: prefer the small window so a phone never gets 1000 cards.
    return true;
  }
  const coarse = window.matchMedia("(pointer: coarse)").matches;
  const narrow = window.matchMedia("(max-width: 768px)").matches;
  const ios = /iPhone|iPad|iPod/i.test(navigator.userAgent);
  return ios || (coarse && narrow);
}

function initialTail(): number {
  return isCoarseMobile() ? MOBILE_INITIAL_TAIL : DESKTOP_INITIAL_TAIL;
}

function olderChunk(): number {
  return isCoarseMobile() ? MOBILE_OLDER_CHUNK : DESKTOP_OLDER_CHUNK;
}

/** Mindlog plus the absolute index of steps[0] in the full log. */
export type MindlogData = Mindlog & { start: number };

/** Delta runs replace their previous versions in place; new runs append.
 * Unchanged runs keep object identity (memo-friendly). */
function mergeRuns(prev: RunGroup[], delta: RunGroup[]): RunGroup[] {
  if (!delta.length) return prev;
  const changed = new Map(delta.map((run) => [run.run_id, run]));
  const merged = prev.map((run) => {
    const update = changed.get(run.run_id);
    if (update) changed.delete(run.run_id);
    return update ?? run;
  });
  for (const run of delta) {
    if (changed.has(run.run_id)) merged.push(run);
  }
  return merged;
}

/** Mind log with windowed loading: the first fetch asks for the newest
 * initialTail() steps only; each poll asks for steps beyond what we hold
 * (?since=N, absolute index) and appends them; runs arrive as deltas
 * (only the ones new steps touched) and are merged by id. loadOlder()
 * prepends the next olderChunk() of history. Old step objects keep their
 * identity, so memoized step components skip re-rendering. A shrunken
 * step_count (log reset/rewritten) falls back to a fresh tail fetch. */
export function useMindlog(identityId: string, live: boolean) {
  const queryClient = useQueryClient();
  const [loadingOlder, setLoadingOlder] = useState(false);

  const query = useQuery({
    queryKey: ["mindlog", identityId],
    queryFn: async (): Promise<MindlogData> => {
      const prev = queryClient.getQueryData<MindlogData>([
        "mindlog",
        identityId,
      ]);
      if (!prev || !prev.steps.length) {
        const first = await fetchMindlog(identityId, { tail: initialTail() });
        return { ...first, start: first.since ?? 0 };
      }
      const held = prev.start + prev.steps.length;
      const delta = await fetchMindlog(identityId, { since: held });
      if (delta.step_count < held) {
        const fresh = await fetchMindlog(identityId, { tail: initialTail() });
        return { ...fresh, start: fresh.since ?? 0 };
      }
      if (!delta.steps.length && !delta.runs.length) {
        return { ...delta, steps: prev.steps, runs: prev.runs, start: prev.start };
      }
      return {
        ...delta,
        steps: delta.steps.length ? [...prev.steps, ...delta.steps] : prev.steps,
        runs: mergeRuns(prev.runs, delta.runs),
        start: prev.start,
      };
    },
    refetchInterval: pollWhileLive(live),
  });

  const loadOlder = useCallback(async () => {
    const prev = queryClient.getQueryData<MindlogData>(["mindlog", identityId]);
    if (!prev || prev.start <= 0) return;
    setLoadingOlder(true);
    try {
      const from = Math.max(0, prev.start - olderChunk());
      const older = await fetchMindlog(identityId, {
        since: from,
        until: prev.start,
      });
      queryClient.setQueryData<MindlogData>(
        ["mindlog", identityId],
        (current) => {
          // A poll-triggered reset while we fetched: drop the stale window.
          if (!current || current.start !== prev.start) return current;
          return {
            ...current,
            steps: [...older.steps, ...current.steps],
            // Windowed runs are current-version objects, so merging the
            // overlap is a no-op; only genuinely older runs append.
            runs: mergeRuns(current.runs, older.runs),
            start: from,
          };
        }
      );
    } finally {
      setLoadingOlder(false);
    }
  }, [identityId, queryClient]);

  return {
    ...query,
    loadOlder,
    loadingOlder,
    hiddenOlder: query.data?.start ?? 0,
  };
}
