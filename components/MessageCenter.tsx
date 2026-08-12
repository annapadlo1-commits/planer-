"use client";

import { Bell, Check, MessageCircle, Plus, RefreshCw, Search, Send, UserRound, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";

type Contact = { authUserId: string; employeeId?: string | null; name: string; email: string; employeeNo?: string | null; roleName?: string | null };
type Conversation = { id: string; subject: string; kind: string; contextType?: string | null; contextId?: string | null; updatedAt: string; unreadCount: number; lastMessage?: string | null; members: { authUserId: string; name: string }[] };
type Message = { id: string; conversationId: string; senderUserId: string; senderName: string; body: string; createdAt: string };
type Workspace = { currentUserId: string; contacts: Contact[]; conversations: Conversation[]; messages: Message[] };

function formatMoment(value: string) {
  return new Intl.DateTimeFormat("pl-PL", { dateStyle: "short", timeStyle: "short" }).format(new Date(value));
}

function errorMessage(value: string) {
  if (value.includes("RECIPIENT_NOT_FOUND")) return "Wybrana osoba nie ma aktywnego dostępu do aplikacji.";
  if (value.includes("CONVERSATION_FORBIDDEN")) return "Nie masz dostępu do tej rozmowy.";
  if (value.includes("EMPTY_MESSAGE")) return "Wpisz treść wiadomości.";
  if (value.includes("AUTH_REQUIRED")) return "Zaloguj się ponownie.";
  return value;
}

export function MessageCenter({ notify, fail }: { notify: (message: string) => void; fail: (message: string) => void }) {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState("");
  const [body, setBody] = useState("");
  const [composeOpen, setComposeOpen] = useState(false);
  const [recipientId, setRecipientId] = useState("");
  const [subject, setSubject] = useState("");
  const [firstMessage, setFirstMessage] = useState("");
  const [contactQuery, setContactQuery] = useState("");
  const bottomRef = useRef<HTMLDivElement | null>(null);

  const load = useCallback(async (quiet = false) => {
    if (!supabase) return;
    if (!quiet) setLoading(true);
    const result = await supabase.rpc("message_center_workspace_uat_v1");
    if (!quiet) setLoading(false);
    if (result.error || !result.data) {
      fail(`Nie udało się pobrać wiadomości: ${errorMessage(result.error?.message || "Brak odpowiedzi serwera.")}`);
      return;
    }
    const next = result.data as Workspace;
    setWorkspace(next);
    setSelectedId(current => current && next.conversations.some(item => item.id === current) ? current : next.conversations[0]?.id ?? null);
  }, [fail, supabase]);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!supabase) return;
    const interval = window.setInterval(() => void load(true), 20_000);
    return () => window.clearInterval(interval);
  }, [load, supabase]);
  useEffect(() => { bottomRef.current?.scrollIntoView({ behavior: "smooth" }); }, [selectedId, workspace?.messages.length]);

  const selected = workspace?.conversations.find(item => item.id === selectedId) ?? null;
  const visibleConversations = (workspace?.conversations ?? []).filter(item => {
    const normalized = query.trim().toLocaleLowerCase("pl-PL");
    return !normalized || `${item.subject} ${item.lastMessage ?? ""} ${item.members.map(member => member.name).join(" ")}`.toLocaleLowerCase("pl-PL").includes(normalized);
  });
  const messages = (workspace?.messages ?? []).filter(item => item.conversationId === selectedId);
  const contacts = (workspace?.contacts ?? []).filter(item => {
    const normalized = contactQuery.trim().toLocaleLowerCase("pl-PL");
    return !normalized || `${item.name} ${item.email} ${item.employeeNo ?? ""} ${item.roleName ?? ""}`.toLocaleLowerCase("pl-PL").includes(normalized);
  });

  const markRead = useCallback(async (conversationId: string) => {
    if (!supabase) return;
    await supabase.rpc("message_mark_read_uat_v1", { p_conversation_id: conversationId });
    setWorkspace(current => current ? { ...current, conversations: current.conversations.map(item => item.id === conversationId ? { ...item, unreadCount: 0 } : item) } : current);
  }, [supabase]);
  const selectConversation = (conversationId: string) => {
    setSelectedId(conversationId);
    void markRead(conversationId);
  };
  const send = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!supabase || !selectedId || !body.trim()) return;
    setBusy(true);
    const result = await supabase.rpc("message_send_uat_v1", { p_conversation_id: selectedId, p_body: body.trim() });
    setBusy(false);
    if (result.error) { fail(errorMessage(result.error.message)); return; }
    setBody("");
    await load(true);
  };
  const createConversation = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!supabase || !recipientId || !firstMessage.trim()) return;
    setBusy(true);
    const result = await supabase.rpc("message_conversation_create_uat_v1", {
      p_recipient_auth_user_id: recipientId,
      p_subject: subject.trim() || "Rozmowa zespołu",
      p_message: firstMessage.trim(),
      p_context_type: null,
      p_context_id: null,
    });
    setBusy(false);
    if (result.error || !result.data) { fail(errorMessage(result.error?.message || "Nie udało się utworzyć rozmowy.")); return; }
    const created = result.data as { conversationId: string };
    setComposeOpen(false); setRecipientId(""); setSubject(""); setFirstMessage(""); setContactQuery("");
    await load(true); setSelectedId(created.conversationId); notify("Rozmowa została utworzona.");
  };

  if (loading) return <section className="message-center-loading"><RefreshCw className="spin" /><strong>Pobieram rozmowy…</strong></section>;
  return <section className="message-center">
    <header><div><p className="eyebrow">KOMUNIKACJA • ZESPÓŁ</p><h2>Wiadomości</h2><p>Rozmowy pracownik–pracownik i pracownik–przełożony, z historią dostępną tylko uczestnikom.</p></div><button className="primary-button" onClick={() => setComposeOpen(true)}><Plus /> Nowa rozmowa</button></header>
    <div className="message-layout">
      <aside className="conversation-list"><label><Search /><input value={query} onChange={event => setQuery(event.target.value)} placeholder="Szukaj osoby lub tematu" /></label><button className="message-refresh" onClick={() => void load()}><RefreshCw /> Odśwież</button>{visibleConversations.map(item => <button key={item.id} className={selectedId === item.id ? "active" : ""} onClick={() => selectConversation(item.id)}><span className="message-avatar"><MessageCircle /></span><span><b>{item.subject}</b><small>{item.members.filter(member => member.authUserId !== workspace?.currentUserId).map(member => member.name).join(", ") || "Rozmowa zespołu"}</small><em>{item.lastMessage || "Brak wiadomości"}</em></span><time>{formatMoment(item.updatedAt)}</time>{item.unreadCount > 0 && <i>{item.unreadCount}</i>}</button>)}{!visibleConversations.length && <p>Nie masz jeszcze rozmów spełniających filtr.</p>}</aside>
      <main className="message-thread">{selected ? <><header><span><Bell /><div><h3>{selected.subject}</h3><p>{selected.members.map(member => member.name).join(" • ")}</p></div></span><small>{selected.kind === "DIRECT" ? "Rozmowa prywatna" : "Rozmowa zespołu"}</small></header><div className="message-stream">{messages.map(message => <article key={message.id} className={message.senderUserId === workspace?.currentUserId ? "mine" : "theirs"}><b>{message.senderName}</b><p>{message.body}</p><time>{formatMoment(message.createdAt)}</time></article>)}{!messages.length && <p className="message-empty">Napisz pierwszą wiadomość w tej rozmowie.</p>}<div ref={bottomRef} /></div><form onSubmit={send}><textarea value={body} onChange={event => setBody(event.target.value)} maxLength={2000} placeholder="Napisz wiadomość…" /><button className="primary-button" disabled={busy || !body.trim()}><Send /> {busy ? "Wysyłam…" : "Wyślij"}</button></form></> : <div className="message-thread-placeholder"><MessageCircle /><h3>Wybierz rozmowę</h3><p>Albo rozpocznij nową z osobą, która ma aktywny dostęp do GRAFIK PRO.</p></div>}</main>
    </div>
    {composeOpen && <><button className="drawer-scrim" onClick={() => setComposeOpen(false)} /><aside className="drawer complete-drawer message-compose"><div className="drawer-head"><div><p className="eyebrow">NOWA WIADOMOŚĆ</p><h2>Rozpocznij rozmowę</h2></div><button className="icon-button" onClick={() => setComposeOpen(false)}><X /></button></div><form className="drawer-content" onSubmit={createConversation}><label>Znajdź osobę<input value={contactQuery} onChange={event => setContactQuery(event.target.value)} placeholder="Imię, e-mail, numer lub rola" /></label><div className="message-contacts">{contacts.map(contact => <button type="button" key={contact.authUserId} className={recipientId === contact.authUserId ? "active" : ""} onClick={() => setRecipientId(contact.authUserId)}><UserRound /><span><b>{contact.name}</b><small>{contact.roleName || contact.email}{contact.employeeNo ? ` • ${contact.employeeNo}` : ""}</small></span>{recipientId === contact.authUserId && <Check />}</button>)}{!contacts.length && <p>Brak osób spełniających filtr.</p>}</div><label>Temat<input value={subject} onChange={event => setSubject(event.target.value)} maxLength={160} placeholder="np. Zamiana w sobotę" /></label><label>Wiadomość<textarea value={firstMessage} onChange={event => setFirstMessage(event.target.value)} maxLength={2000} required /></label><button className="primary-button full" disabled={busy || !recipientId || !firstMessage.trim()}><Send /> {busy ? "Tworzę rozmowę…" : "Wyślij i rozpocznij rozmowę"}</button></form></aside></>}
  </section>;
}
