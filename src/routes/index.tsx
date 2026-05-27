import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";
import { ArrowBigUp, Send } from "lucide-react";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Live Q&A" },
      { name: "description", content: "실시간 질문을 남기고 추천해 주세요." },
      { property: "og:title", content: "Live Q&A" },
      { property: "og:description", content: "실시간 질문을 남기고 추천해 주세요." },
    ],
  }),
  component: QnAPage,
});

type Question = {
  id: string;
  text: string;
  upvotes: number;
  created_at: string;
};

const STORAGE_KEY = "qna_upvoted_ids_v1";

function getUpvotedSet(): Set<string> {
  if (typeof window === "undefined") return new Set();
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return new Set(raw ? (JSON.parse(raw) as string[]) : []);
  } catch {
    return new Set();
  }
}

function saveUpvotedSet(set: Set<string>) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify([...set]));
  } catch {
    /* ignore */
  }
}

function QnAPage() {
  const [questions, setQuestions] = useState<Question[]>([]);
  const [upvoted, setUpvoted] = useState<Set<string>>(new Set());
  const [text, setText] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [loading, setLoading] = useState(true);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setUpvoted(getUpvotedSet());

    let isMounted = true;
    (async () => {
      const { data } = await supabase
        .from("questions")
        .select("*")
        .order("upvotes", { ascending: false })
        .order("created_at", { ascending: false })
        .limit(200);
      if (isMounted && data) setQuestions(data as Question[]);
      if (isMounted) setLoading(false);
    })();

    const channel = supabase
      .channel("questions-changes")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "questions" },
        (payload) => {
          setQuestions((prev) => {
            if (payload.eventType === "INSERT") {
              const q = payload.new as Question;
              if (prev.some((p) => p.id === q.id)) return prev;
              return sortQs([q, ...prev]);
            }
            if (payload.eventType === "UPDATE") {
              const q = payload.new as Question;
              return sortQs(prev.map((p) => (p.id === q.id ? q : p)));
            }
            if (payload.eventType === "DELETE") {
              const q = payload.old as Question;
              return prev.filter((p) => p.id !== q.id);
            }
            return prev;
          });
        },
      )
      .subscribe();

    return () => {
      isMounted = false;
      supabase.removeChannel(channel);
    };
  }, []);

  const sortQs = (arr: Question[]) =>
    [...arr].sort((a, b) => {
      if (b.upvotes !== a.upvotes) return b.upvotes - a.upvotes;
      return new Date(b.created_at).getTime() - new Date(a.created_at).getTime();
    });

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const trimmed = text.trim();
    if (!trimmed || submitting) return;
    setSubmitting(true);
    const { error } = await supabase.from("questions").insert({ text: trimmed });
    setSubmitting(false);
    if (!error) {
      setText("");
      inputRef.current?.blur();
    }
  }

  async function handleUpvote(q: Question) {
    if (upvoted.has(q.id)) return;
    const next = new Set(upvoted);
    next.add(q.id);
    setUpvoted(next);
    saveUpvotedSet(next);
    // optimistic
    setQuestions((prev) =>
      sortQs(prev.map((p) => (p.id === q.id ? { ...p, upvotes: p.upvotes + 1 } : p))),
    );
    const { error } = await supabase
      .from("questions")
      .update({ upvotes: q.upvotes + 1 })
      .eq("id", q.id);
    if (error) {
      // revert
      const reverted = new Set(next);
      reverted.delete(q.id);
      setUpvoted(reverted);
      saveUpvotedSet(reverted);
      setQuestions((prev) =>
        sortQs(prev.map((p) => (p.id === q.id ? { ...p, upvotes: p.upvotes - 1 } : p))),
      );
    }
  }

  return (
    <div className="min-h-screen bg-background flex flex-col">
      <header className="sticky top-0 z-10 bg-background border-b border-border">
        <div className="max-w-2xl mx-auto px-4 py-4">
          <h1 className="text-xl font-bold tracking-tight">Live Q&amp;A</h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            질문을 남기고 좋은 질문에 추천을 눌러주세요.
          </p>
        </div>
      </header>

      <main className="flex-1 w-full max-w-2xl mx-auto px-4 pt-4 pb-36">
        {loading ? (
          <p className="text-sm text-muted-foreground text-center mt-12">불러오는 중…</p>
        ) : questions.length === 0 ? (
          <div className="text-center mt-16">
            <p className="text-base font-medium">아직 질문이 없습니다</p>
            <p className="text-sm text-muted-foreground mt-1">첫 질문을 남겨보세요!</p>
          </div>
        ) : (
          <ul className="flex flex-col gap-2">
            {questions.map((q) => {
              const hasUpvoted = upvoted.has(q.id);
              return (
                <li
                  key={q.id}
                  className="flex items-stretch gap-3 bg-card border border-border rounded-lg p-3"
                >
                  <button
                    onClick={() => handleUpvote(q)}
                    disabled={hasUpvoted}
                    aria-label="추천"
                    className={`flex flex-col items-center justify-center min-w-14 px-2 py-1.5 rounded-md border transition-colors ${
                      hasUpvoted
                        ? "bg-primary border-primary text-primary-foreground"
                        : "bg-background border-border text-foreground hover:border-primary hover:text-primary active:bg-primary/5"
                    }`}
                  >
                    <ArrowBigUp
                      className="w-5 h-5"
                      strokeWidth={2}
                      fill={hasUpvoted ? "currentColor" : "none"}
                    />
                    <span className="text-sm font-semibold leading-none mt-0.5 tabular-nums">
                      {q.upvotes}
                    </span>
                  </button>
                  <p className="flex-1 text-[15px] leading-relaxed break-words self-center whitespace-pre-wrap">
                    {q.text}
                  </p>
                </li>
              );
            })}
          </ul>
        )}
      </main>

      <form
        onSubmit={handleSubmit}
        className="fixed bottom-0 inset-x-0 bg-background border-t border-border"
      >
        <div className="max-w-2xl mx-auto px-4 py-3 flex items-center gap-2">
          <input
            ref={inputRef}
            type="text"
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="질문을 입력하세요…"
            maxLength={500}
            className="flex-1 h-11 px-4 rounded-full bg-muted border border-transparent focus:bg-background focus:border-primary focus:outline-none text-[15px]"
          />
          <button
            type="submit"
            disabled={!text.trim() || submitting}
            aria-label="질문 보내기"
            className="h-11 w-11 flex items-center justify-center rounded-full bg-primary text-primary-foreground disabled:opacity-40 disabled:cursor-not-allowed transition-opacity active:opacity-80"
          >
            <Send className="w-5 h-5" />
          </button>
        </div>
      </form>
    </div>
  );
}
