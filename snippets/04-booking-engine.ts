// A channel-independent booking conversation (illustrative, written for this case study).
//
// The engine is a pure function: (state, incoming message) -> (new state, replies).
// It knows nothing about WhatsApp or Telegram, so the same code runs on every
// channel and is unit-tested without either. A language model may turn free text
// into an intent, but only through a validated, closed set of shapes; slots and
// the booking itself stay with deterministic code.

export type Step = "reason" | "slot" | "name" | "confirm" | "done";

export interface State {
  step: Step;
  reason?: string;
  slot?: string; // ISO start time
  name?: string;
}

export type Incoming = { kind: "text"; text: string } | { kind: "choice"; id: string };

export type Reply =
  | { kind: "text"; text: string }
  | { kind: "choices"; text: string; options: { id: string; label: string }[] };

export interface Deps {
  reasons: { id: string; label: string }[];
  freeSlots(reasonId: string, day?: string): Promise<{ id: string; label: string }[]>;
  /** Optional: free text -> intent. Returns null when unsure or unavailable. */
  interpret?(text: string): Promise<Intent | null>;
  book(state: Required<Pick<State, "reason" | "slot" | "name">>): Promise<"ok" | "taken">;
}

export type Intent = { intent: "book"; day?: string; partOfDay?: "morning" | "afternoon" } | { intent: "other" };

/** Accept a model's JSON only if it has exactly the shape we expect. */
export function parseIntent(raw: unknown): Intent | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (r.intent === "other") return { intent: "other" };
  if (r.intent !== "book") return null;
  const day = typeof r.day === "string" && /^\d{4}-\d{2}-\d{2}$/.test(r.day) ? r.day : undefined;
  const partOfDay = r.partOfDay === "morning" || r.partOfDay === "afternoon" ? r.partOfDay : undefined;
  return { intent: "book", day, partOfDay };
}

const ask = (text: string, options: { id: string; label: string }[]): Reply => ({ kind: "choices", text, options });

export async function step(state: State, msg: Incoming, deps: Deps): Promise<{ state: State; replies: Reply[] }> {
  const choice = msg.kind === "choice" ? msg.id : undefined;

  switch (state.step) {
    case "reason": {
      const reason = deps.reasons.find((r) => r.id === choice);
      if (!reason) {
        // Free text? Let the model read it, but only to skip ahead, never to book.
        const intent = msg.kind === "text" && deps.interpret ? await deps.interpret(msg.text) : null;
        const hint = intent?.intent === "book" ? "اختر سبب الزيارة لنكمل الحجز:" : "ما سبب زيارتك؟";
        return { state, replies: [ask(hint, deps.reasons)] };
      }
      const slots = await deps.freeSlots(reason.id);
      return { state: { step: "slot", reason: reason.id }, replies: [ask("اختر الوقت المناسب:", slots)] };
    }
    case "slot": {
      if (!choice) return { state, replies: [ask("اختر الوقت المناسب:", await deps.freeSlots(state.reason!))] };
      return { state: { ...state, step: "name", slot: choice }, replies: [{ kind: "text", text: "ما اسم المريض؟" }] };
    }
    case "name": {
      const name = msg.kind === "text" ? msg.text.trim() : "";
      if (name.length < 2) return { state, replies: [{ kind: "text", text: "ما اسم المريض؟" }] };
      return {
        state: { ...state, step: "confirm", name },
        replies: [ask(`تأكيد الموعد باسم ${name}؟`, [{ id: "yes", label: "تأكيد" }, { id: "no", label: "إلغاء" }])],
      };
    }
    case "confirm": {
      if (choice !== "yes") return { state: { step: "reason" }, replies: [ask("ما سبب زيارتك؟", deps.reasons)] };
      // The appointment is created only here, and only through the database's race-safe booking function.
      const result = await deps.book({ reason: state.reason!, slot: state.slot!, name: state.name! });
      if (result === "taken") {
        return { state: { step: "slot", reason: state.reason }, replies: [ask("حُجز هذا الوقت للتوّ، اختر وقتاً آخر:", await deps.freeSlots(state.reason!))] };
      }
      return { state: { step: "done" }, replies: [{ kind: "text", text: "تمّ حجز موعدك ✅" }] };
    }
    case "done":
      return { state: { step: "reason" }, replies: [ask("ما سبب زيارتك؟", deps.reasons)] };
  }
}

// Each channel only translates: WhatsApp interactive lists (or a numbered list
// where they are not available), Telegram inline keyboards, and back.
