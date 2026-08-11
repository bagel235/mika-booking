"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Search, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { bookingTypes, money, sourceLabels, statusLabels, type BookingType, typeLabels } from "@/lib/booking";

type Booking = {
  id: string; booking_number: string; customer_name: string; contact: string;
  booking_date: string; start_time: string; end_time: string; duration_hours: number;
  booking_type: BookingType; companion_count: number; camera_preference: string | null;
  standard_price: number; price_adjustment: number; final_price: number;
  deposit_due: number; deposit_paid: number; balance_due: number; status: string;
  booking_source: string; notes: string | null; staff_notes: string | null;
};
type RescheduleForm = { date: string; start: string; duration: number; type: BookingType; companions: number; adjustment: number; reason: string };
type Preview = { standard: number; final: number; balance: number };

export function Bookings() {
  const supabase = useMemo(() => createClient(), []);
  const [items, setItems] = useState<Booking[]>([]);
  const [filter, setFilter] = useState("HOLD");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<Booking | null>(null);

  const load = useCallback(async () => {
    if (!supabase) return;
    const { data } = await supabase.from("bookings").select("*").order("booking_date").order("start_time");
    const bookings = (data as Booking[] | null) ?? [];
    setItems(bookings);
    setSelected(current => current ? bookings.find(item => item.id === current.id) ?? null : null);
  }, [supabase]);

  useEffect(() => { const id = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(id); }, [load]);

  async function confirmPayment(id: string, due: number) {
    const value = prompt("实际收到定金金额", String(due));
    if (value !== null && supabase) { await supabase.rpc("confirm_booking_payment", { p_booking: id, p_paid: +value }); await load(); }
  }
  async function cancel(id: string) {
    if (window.confirm("确认取消这笔预约？") && supabase) { await supabase.rpc("cancel_booking", { p_booking: id }); await load(); }
  }

  const shown = items.filter(item => (filter === "ALL" || item.status === filter)
    && `${item.customer_name}${item.contact}${item.booking_number}`.toLowerCase().includes(query.toLowerCase()));

  return <div className="p-4 pb-24 md:p-8">
    <p className="eyebrow">BOOKINGS</p><h1 className="mt-1 text-3xl font-black">预约管理</h1>
    <div className="mt-6 flex flex-wrap gap-2">{[["HOLD", "待确认定金"], ["CONFIRMED", "已确认"], ["ALL", "全部预约"]].map(option => <button key={option[0]} className={`choice !px-4 !py-2 ${filter === option[0] ? "active" : ""}`} onClick={() => setFilter(option[0])}>{option[1]}</button>)}</div>
    <div className="relative mt-4 max-w-md"><Search className="absolute left-3 top-3.5 h-4 w-4 muted" /><input className="field !pl-10" placeholder="搜索客户、联系方式或预约编号" value={query} onChange={event => setQuery(event.target.value)} /></div>
    {!supabase && <p className="mt-4 rounded-xl bg-amber-50 p-3 text-sm text-amber-800">请配置 Supabase 连接以管理真实预约。</p>}
    <div className="mt-5 space-y-3">{shown.map(booking => <article className="card grid w-full gap-4 p-5 lg:grid-cols-[1.2fr_1fr_1fr_auto] lg:items-center" key={booking.id}>
      <button type="button" className="text-left lg:col-span-3" onClick={() => setSelected(booking)}>
        <div className="grid gap-4 lg:grid-cols-[1.2fr_1fr_1fr] lg:items-center">
          <div><div className="flex items-center gap-2"><b className="text-lg">{booking.customer_name}</b><span className={`badge ${booking.status === "HOLD" ? "badge-yellow" : "badge-green"}`}>{statusLabels[booking.status]}</span></div><p className="mt-1 text-sm muted">{booking.contact}</p><p className="mt-1 text-xs font-bold text-[var(--rose)]">预约编号 {booking.booking_number}</p>{booking.staff_notes && <p className="mt-2 line-clamp-2 text-xs muted">店员备注：{booking.staff_notes}</p>}</div>
          <div><b>{booking.booking_date}</b><p className="text-sm muted">{timeRange(booking)} · {typeLabels[booking.booking_type]}</p></div>
          <div><b>{money(booking.final_price)}</b><p className="text-sm muted">定金 {money(booking.deposit_due)} · {sourceLabels[booking.booking_source]}</p></div>
        </div>
      </button>
      <div className="flex flex-wrap gap-2 lg:justify-end">
        <button type="button" className="btn border border-[var(--line)] bg-white !px-3 !py-2 text-sm" onClick={() => setSelected(booking)}>查看详情</button>
        {booking.status === "HOLD" && <button type="button" className="btn !bg-[var(--green)] !px-3 !py-2 text-sm text-white" onClick={() => void confirmPayment(booking.id, booking.deposit_due)}>确认收款</button>}
        {["HOLD", "CONFIRMED"].includes(booking.status) && <button type="button" className="btn !bg-red-50 !px-3 !py-2 text-sm text-red-700" onClick={() => void cancel(booking.id)}>取消</button>}
      </div>
    </article>)}{supabase && !shown.length && <div className="card p-10 text-center muted">没有符合条件的预约。</div>}</div>
    {selected && <BookingDialog booking={selected} onClose={() => setSelected(null)} onSaved={load} />}
  </div>;
}

function BookingDialog({ booking, onClose, onSaved }: { booking: Booking; onClose: () => void; onSaved: () => Promise<void> }) {
  const supabase = useMemo(() => createClient(), []);
  const [staffNotes, setStaffNotes] = useState(booking.staff_notes ?? "");
  const [noteMessage, setNoteMessage] = useState("");
  const [rescheduling, setRescheduling] = useState(false);
  const [form, setForm] = useState<RescheduleForm>({ date: booking.booking_date, start: booking.start_time.slice(0, 5), duration: booking.duration_hours, type: booking.booking_type, companions: booking.companion_count, adjustment: Number(booking.price_adjustment), reason: "" });
  const [preview, setPreview] = useState<Preview | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);

  async function saveNotes() {
    if (!supabase) return;
    setBusy(true);
    const { error } = await supabase.from("bookings").update({ staff_notes: staffNotes.trim() || null }).eq("id", booking.id);
    setBusy(false);
    setNoteMessage(error ? "备注保存失败，请重试。" : "店员备注已保存。由员工权限保护，不会显示给顾客。");
    if (!error) await onSaved();
  }

  function updateForm<K extends keyof RescheduleForm>(key: K, value: RescheduleForm[K]) {
    setForm(current => ({ ...current, [key]: value }));
    setPreview(null);
    setMessage("");
  }

  async function previewReschedule() {
    if (!supabase) return;
    setBusy(true); setMessage("");
    const companions = form.type === "PRIVATE" ? 0 : Number(form.companions);
    const { data, error } = await supabase.rpc("calculate_price", { p_date: form.date, p_type: form.type, p_duration: Number(form.duration), p_companions: companions });
    setBusy(false);
    if (error || !data?.[0]) { setMessage("无法计算新价格，请检查改期信息。"); return; }
    const standard = Number(data[0].standard_price);
    const final = standard + Number(form.adjustment);
    if (final < 0) { setMessage("价格调整后订单总价不能小于 0。"); return; }
    setPreview({ standard, final, balance: Math.max(final - Number(booking.deposit_paid), 0) });
  }

  async function commitReschedule() {
    if (!supabase || !preview) return;
    setBusy(true); setMessage("");
    const { error } = await supabase.rpc("reschedule_booking", {
      p_booking: booking.id, p_date: form.date, p_start: form.start,
      p_duration: Number(form.duration), p_type: form.type,
      p_companions: form.type === "PRIVATE" ? 0 : Number(form.companions),
      p_adjustment: Number(form.adjustment), p_reason: form.reason.trim() || null,
    });
    setBusy(false);
    if (error) { setMessage(error.message.includes("SLOT_UNAVAILABLE") ? "新时段不可用，原预约和原时段均未发生变化。" : error.message.includes("BOOKING_NOT_CONFIRMED") ? "只有已确认预约可以改期。" : "改期失败，请检查信息后重试。"); return; }
    await onSaved();
    onClose();
  }

  const details = [["预约编号", booking.booking_number], ["客户姓名 / 昵称", booking.customer_name], ["联系方式", booking.contact], ["预约日期", booking.booking_date], ["完整预约时间", timeRange(booking)], ["预约项目", typeLabels[booking.booking_type]], ["陪同人数", `${booking.companion_count} 人`], ["相机需求", booking.camera_preference || "不需要"], ["预约总价", money(booking.final_price)], ["应收定金", money(booking.deposit_due)], ["实际已付定金", money(booking.deposit_paid)], ["到店待付", money(booking.balance_due)], ["预约状态", statusLabels[booking.status]], ["预约来源", sourceLabels[booking.booking_source]], ["顾客备注", booking.notes || "无"]];

  return <div className="fixed inset-0 z-40 grid place-items-end bg-[#68445255] sm:place-items-center sm:p-5" onClick={onClose}><div role="dialog" aria-modal="true" aria-label="预约详情" className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-t-3xl bg-white p-6 sm:rounded-3xl" onClick={event => event.stopPropagation()}>
    <div className="flex items-start justify-between"><div><p className="text-xs font-bold text-[var(--rose)]">预约详情</p><h2 className="mt-1 text-2xl font-black">{booking.booking_number}</h2></div><button type="button" aria-label="关闭" onClick={onClose}><X /></button></div>
    <dl className="mt-6 grid gap-4 sm:grid-cols-2">{details.map(([label, value]) => <div key={label}><dt className="text-xs muted">{label}</dt><dd className="mt-1 whitespace-pre-wrap font-medium">{value}</dd></div>)}</dl>
    <section className="mt-7 border-t border-[var(--line)] pt-6"><label className="text-sm font-black">店员备注<textarea className="field mt-2" rows={4} value={staffNotes} onChange={event => setStaffNotes(event.target.value)} placeholder="仅店员可见" /></label>{noteMessage && <p className="mt-2 text-sm muted">{noteMessage}</p>}<button type="button" className="btn btn-primary mt-3" disabled={busy} onClick={() => void saveNotes()}>保存备注</button></section>
    {booking.status === "CONFIRMED" && <section className="mt-7 border-t border-[var(--line)] pt-6"><button type="button" className="btn !bg-[var(--ink)] text-white" onClick={() => setRescheduling(value => !value)}>改期</button>{rescheduling && <div className="mt-5 rounded-2xl bg-[var(--soft)] p-5">
      <div className="grid gap-4 sm:grid-cols-2"><Field label="新日期"><input className="field" type="date" value={form.date} onChange={event => updateForm("date", event.target.value)} /></Field><Field label="新开始时间"><select className="field" value={form.start} onChange={event => updateForm("start", event.target.value)}>{Array.from({ length: 15 }, (_, i) => `${String(i + 9).padStart(2, "0")}:00`).map(time => <option key={time}>{time}</option>)}</select></Field><Field label="新时长"><input className="field" type="number" min="1" max="15" value={form.duration} onChange={event => updateForm("duration", Number(event.target.value))} /></Field><Field label="预约项目"><select className="field" value={form.type} onChange={event => updateForm("type", event.target.value as BookingType)}>{bookingTypes.map(type => <option value={type} key={type}>{typeLabels[type]}</option>)}</select></Field>{form.type !== "PRIVATE" && <Field label="陪同人数"><input className="field" type="number" min="0" value={form.companions} onChange={event => updateForm("companions", Number(event.target.value))} /></Field>}<Field label="价格调整"><input className="field" type="number" step="0.01" value={form.adjustment} onChange={event => updateForm("adjustment", Number(event.target.value))} /></Field></div>
      <Field label="改期原因 / 备注"><textarea className="field" rows={3} value={form.reason} onChange={event => updateForm("reason", event.target.value)} placeholder="仅记录在内部改期历史" /></Field>
      <button type="button" className="btn mt-4 border border-[var(--line)] bg-white" disabled={busy} onClick={() => void previewReschedule()}>预览改期</button>
      {preview && <div className="mt-5 rounded-2xl bg-white p-4"><dl className="grid grid-cols-2 gap-y-3 text-sm"><dt className="muted">原预约时间</dt><dd className="text-right font-bold">{booking.booking_date} {timeRange(booking)}</dd><dt className="muted">新预约时间</dt><dd className="text-right font-bold">{form.date} {form.start}–{endTime(form.start, form.duration)}</dd><dt className="muted">原订单总价</dt><dd className="text-right font-bold">{money(booking.final_price)}</dd><dt className="muted">新标准价</dt><dd className="text-right font-bold">{money(preview.standard)}</dd><dt className="muted">价格调整</dt><dd className="text-right font-bold">{money(form.adjustment)}</dd><dt className="muted">新订单总价</dt><dd className="text-right font-bold">{money(preview.final)}</dd><dt className="muted">已付定金</dt><dd className="text-right font-bold">{money(booking.deposit_paid)}</dd><dt className="muted">改期后待付金额</dt><dd className="text-right font-black text-[var(--rose)]">{money(preview.balance)}</dd></dl>{Number(booking.deposit_paid) > preview.final && <p className="mt-4 rounded-xl bg-amber-50 p-3 text-sm font-bold text-amber-800">已付金额高于改期后订单金额，请人工处理差额。</p>}<button type="button" className="btn btn-primary mt-5 w-full" disabled={busy} onClick={() => void commitReschedule()}>{busy ? "正在改期…" : "确认改期"}</button></div>}
      {message && <p className="mt-3 rounded-xl bg-rose-50 p-3 text-sm text-rose-700">{message}</p>}
    </div>}</section>}
  </div></div>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="mt-4 block text-sm font-bold">{label}<div className="mt-2">{children}</div></label>; }
function timeRange(booking: Booking) { return `${booking.start_time.slice(0, 5)}–${booking.end_time.slice(0, 5)}`; }
function endTime(start: string, duration: number) { return `${String(Number(start.slice(0, 2)) + Number(duration)).padStart(2, "0")}:00`; }
