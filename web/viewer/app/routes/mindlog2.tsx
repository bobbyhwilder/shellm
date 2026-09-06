import { useQuery } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { ExternalLink, Maximize2, Minimize2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router";

import { IdentityTabs } from "~/components/identity-tabs";
import { LoadingDots } from "~/components/ui/loading-dots";
import { fetchActivity, fetchIdentityStatus } from "~/lib/api";
import { toCard, type CardGroup, type Ml2Card } from "~/lib/mindlog2-model";
import { useMindlog } from "~/lib/use-mindlog";
import { cn } from "~/lib/utils";

export function meta() {
  return [{ title: "Headlong · mind log v2" }];
}

/** Presentation stream: newest first, so a calm page with no scroll chasing. */
/** Clamp long bodies; the video's one-liners are not how Audel writes. */
const CLAMP_CHARS = 420;

const LEGEND: { group: CardGroup; label: string; dot: string }[] = [
  { group: "thought", label: "thought", dot: "bg-violet-400" },
  { group: "observation", label: "observation", dot: "bg-pink-500" },
  { group: "message", label: "message", dot: "bg-teal-300" },
];

const CARD_STYLE: Record<Ml2Card["kind"], { card: string; label: string }> = {
  thought: {
    card: "border-l-4 border-violet-500 bg-white/[0.04]",
    label: "text-violet-300",
  },
  observation: {
    card: "border-l-4 border-pink-500 bg-white/[0.04]",
    label: "text-pink-400",
  },
  outbound: {
    card: "ml-auto max-w-2xl border border-teal-400/40 bg-teal-400/15",
    label: "text-teal-300",
  },
  inbound: {
    card: "max-w-2xl border border-indigo-400/40 bg-indigo-400/20",
    label: "text-indigo-300",
  },
};

function fmtTime(ts: string): string {
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString([], {
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function StatusPill({ identityId }: { identityId: string }) {
  const { data: activity } = useQuery({
    queryKey: ["activity", identityId],
    queryFn: () => fetchActivity(identityId),
    refetchInterval: 2000,
  });
  const state = activity?.state ?? "asleep";
  const on = state === "working";
  const stalled = state === "stalled";
  return (
    <span
      className={cn(
        "flex items-center gap-2 rounded-full border px-3.5 py-1 font-mono text-sm",
        on && "border-green-400/50 text-green-300",
        stalled && "border-amber-400/50 text-amber-300",
        !on && !stalled && "border-zinc-600 text-zinc-400"
      )}
    >
      <span className="relative flex h-2 w-2">
        {on && (
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-400 opacity-75" />
        )}
        <span
          className={cn(
            "relative inline-flex h-2 w-2 rounded-full",
            on ? "bg-green-400" : stalled ? "bg-amber-400" : "bg-zinc-500"
          )}
        />
      </span>
      {state}
    </span>
  );
}

function StreamCard({ card, animate }: { card: Ml2Card; animate: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const long = card.body.length > CLAMP_CHARS;
  const body = expanded || !long ? card.body : `${card.body.slice(0, CLAMP_CHARS)}…`;
  const style = CARD_STYLE[card.kind];
  return (
    <div
      className={cn(
        "w-full max-w-3xl rounded-2xl px-6 py-5 shadow-lg shadow-black/20",
        style.card,
        animate && "ml2-enter",
        long && "cursor-pointer"
      )}
      onClick={long ? () => setExpanded((v) => !v) : undefined}
      title={long && !expanded ? "click to expand" : undefined}
    >
      <div className="mb-2 flex items-baseline gap-4">
        <span className={cn("font-mono text-sm tracking-wide", style.label)}>
          {card.label}
        </span>
        {card.source_url && (
          <a
            href={card.source_url}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1 font-mono text-xs text-zinc-400 hover:text-zinc-100 hover:underline"
            onClick={(event) => event.stopPropagation()}
          >
            Open in Slack <ExternalLink className="h-3 w-3" />
          </a>
        )}
        <span className="ml-auto font-mono text-sm tabular-nums text-zinc-500">
          {fmtTime(card.ts)}
        </span>
      </div>
      <div className="whitespace-pre-wrap text-lg leading-snug text-zinc-100 md:text-2xl">
        {body}
      </div>
    </div>
  );
}

export default function Mindlog2Page() {
  const { identityId = "" } = useParams();
  const [hidden, setHidden] = useState<Set<CardGroup>>(new Set());
  const [fullscreen, setFullscreen] = useState(false);

  const { data: status } = useQuery({
    queryKey: ["status", identityId],
    queryFn: () => fetchIdentityStatus(identityId),
    refetchInterval: 2000,
  });
  const live = status?.live ?? false;

  const { data: mindlog, isLoading } = useMindlog(identityId, live);

  // Steps already held when the page first rendered don't animate; only
  // steps that arrive live afterwards slide in.
  const initialEndRef = useRef<number | null>(null);
  useEffect(() => {
    if (mindlog && initialEndRef.current === null) {
      initialEndRef.current = mindlog.start + mindlog.steps.length;
    }
  }, [mindlog]);
  const cards = useMemo(() => {
    if (!mindlog) return [];
    const all = mindlog.steps
      .map((step, idx) => toCard(step, mindlog.identity.name))
      .filter((c): c is Ml2Card => c !== null);
    const visible = all.filter((c) => !hidden.has(c.group));
    return visible.map((card, abs) => ({ card, abs }));
  }, [mindlog, hidden]);

  // Virtualizer for the stream
  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: cards.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 200,
    overscan: 10,
  });

  const toggle = useCallback((group: CardGroup) => {
    setHidden((prev) => {
      const next = new Set(prev);
      if (next.has(group)) next.delete(group);
      else next.add(group);
      return next;
    });
  }, []);

  useEffect(() => {
    if (!fullscreen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFullscreen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [fullscreen]);

  const displayName = mindlog?.identity.name ?? identityId.split("~").pop() ?? identityId;

  const counts = useMemo(() => {
    const c = new Map<CardGroup, number>();
    if (!mindlog) return c;
    for (const step of mindlog.steps) {
      const card = toCard(step, mindlog.identity.name);
      if (card) c.set(card.group, (c.get(card.group) ?? 0) + 1);
    }
    return c;
  }, [mindlog]);

  const canvas = (
    <div
      className={cn(
        "ml2-canvas relative text-zinc-100",
        fullscreen
          ? "min-h-full px-6 py-6 md:px-12"
          : "min-h-[80vh] rounded-2xl border border-zinc-800 px-5 py-5 md:px-10 md:py-8"
      )}
    >
      <header className="flex items-center gap-4">
        <span className="text-2xl font-bold tracking-tight text-white">headlong</span>
        <div className="ml-auto flex items-center gap-3">
          <span className="font-mono text-lg text-zinc-300">{displayName}</span>
          <StatusPill identityId={identityId} />
          <button
            type="button"
            onClick={() => setFullscreen((v) => !v)}
            className="rounded-md border border-zinc-700 p-1.5 text-zinc-400 hover:text-zinc-100"
            title={fullscreen ? "exit fullscreen (Esc)" : "fullscreen"}
          >
            {fullscreen ? <Minimize2 className="h-4 w-4" /> : <Maximize2 className="h-4 w-4" />}
          </button>
        </div>
      </header>
      <div className="mt-4 border-t border-zinc-800" />

      <div className="mt-6 flex gap-8">
        <aside className="hidden w-44 shrink-0 pt-2 sm:block">
          <h3 className="mb-3 font-mono text-xs uppercase tracking-[0.2em] text-zinc-500">
            Step types
          </h3>
          <div className="space-y-2.5">
            {LEGEND.map(({ group, label, dot }) => (
              <button
                key={group}
                type="button"
                onClick={() => toggle(group)}
                className={cn(
                  "flex w-full items-center gap-2.5 font-mono text-sm",
                  hidden.has(group) ? "text-zinc-600 line-through" : "text-zinc-200"
                )}
              >
                <span className={cn("h-2 w-2 rounded-sm", dot)} />
                <span className="flex-1 text-left">{label}</span>
                <span className="tabular-nums text-zinc-500">
                  {counts.get(group) ?? 0}
                </span>
              </button>
            ))}
          </div>
        </aside>

        <main className="min-w-0 flex-1 border-l border-zinc-800 pl-6 md:pl-10">
          <div className="flex items-baseline">
            <h2 className="text-4xl font-extrabold tracking-tight text-white md:text-5xl">
              MINDLOG
            </h2>
            <span className="ml-auto font-mono text-sm text-zinc-500">
              {live ? "live stream" : "not live"}
            </span>
          </div>

          <div className="mt-6" ref={parentRef} style={{ height: "100%", overflow: "auto" }}>
            {cards.length === 0 && (
              <div className="py-16 text-center font-mono text-sm text-zinc-500">
                waiting for thoughts…
              </div>
            )}
            <div
              style={{
                height: `${virtualizer.getTotalSize()}px`,
                width: "100%",
                position: "relative",
              }}
            >
              {virtualizer.getVirtualItems().map((virtualRow) => (
                <div
                  key={cards[virtualRow.index].card.step_id || virtualRow.index}
                  style={{
                    position: "absolute",
                    top: 0,
                    left: 0,
                    width: "100%",
                    height: `${virtualRow.size}px`,
                    transform: `translateY(${virtualRow.start}px)`,
                  }}
                >
                  <StreamCard
                    card={cards[virtualRow.index].card}
                    animate={
                      initialEndRef.current !== null &&
                      cards[virtualRow.index].abs >= initialEndRef.current
                    }
                  />
                </div>
              ))}
            </div>
          </div>
        </main>
      </div>
    </div>
  );

  if (isLoading) {
    return (
      <div className="flex justify-center py-20">
        <LoadingDots />
      </div>
    );
  }

  if (fullscreen) {
    return <div className="fixed inset-0 z-50 overflow-y-auto bg-[#0b0a10]">{canvas}</div>;
  }

  return (
    <div className="mx-auto w-full max-w-7xl px-4">
      <IdentityTabs
        identityId={identityId}
        live={live}
        active="mindlog2"
        name={mindlog?.identity.name}
      />
      {canvas}
    </div>
  );
}
