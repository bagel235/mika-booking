"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { addDays, format, startOfWeek } from "date-fns";
import { zhCN } from "date-fns/locale";
import { ChevronLeft, ChevronRight, X } from "lucide-react";
import { Brand } from "@/components/brand";
import { createClient } from "@/lib/supabase/client";
import { money, sourceLabels, statusLabels, type BookingType, typeLabels } from "@/lib/booking";

type View = "today" | "week";
type Booking = {
  id: string;
  booking_number: string;
  customer_name: string;
  contact: string;
  booking_date: string;
  start_time: string;
  end_time: string;
  booking_type: BookingType;
  companion_count: number;
  camera_preference: string | null;
  final_price: number;
  deposit_due: number;
  deposit_paid: number;
  balance_due: number;
  status: string;
  booking_source: string;
  notes: string | null;
  staff_notes: string | null;
  hold_expires_at: string | null;
};
type OccupancyRow = {
  booking_date: string;
  slot_start: string;
  normal_groups: number;
  has_private: boolean;
};
type SelectedSlot = { date: string; hour: number; bookings: Booking[]; label: string };

const bookingSelect = "id,booking_number,customer_name,contact,booking_date,start_time,end_time,booking_type,companion_count,camera_preference,final_price,deposit_due,deposit_paid,balance_due,status,booking_source,notes,staff_notes,hold_expires_at";

export function Timetable() {
  const supabase = useMemo(() => createClient(), []);
  const [view, setView] = useState<View>("today");
  const [anchor, setAnchor] = useState(new Date());
  const [occupancy, setOccupancy] = useState<OccupancyRow[]>([]);
  const [selectedSlot, setSelectedSlot] = useState<SelectedSlot | null>(null);
  const [selectedBooking, setSelectedBooking] = useState<Booking | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [syncError, setSyncError] = useState("");
  const [selectedLoading, setSelectedLoading] = useState(false);
  const [now, setNow] = useState(0);

  const days = useMemo(() => view === "today"
    ? [anchor]
    : Array.from({ length: 7 }, (_, i) => addDays(startOfWeek(anchor, { weekStartsOn: 1 }), i)), [anchor, view]);
  const from = format(days[0], "yyyy-MM-dd");
  const to = format(days.at(-1)!, "yyyy-MM-dd");

  const loadOccupancy = useCallback(async () => {
    if (!supabase) return;
    setRefreshing(true);
    const { data, error } = await supabase.rpc("public_slot_occupancy", {
      p_from: from,
      p_to: to,
    });
    if (error) {
      setSyncError(error.message);
    } else {
      setOccupancy((data as OccupancyRow[] | null) ?? []);
      setSyncError("");
    }
    setRefreshing(false);
  }, [from, supabase, to]);

  useEffect(() => {
    const initial = window.setTimeout(() => void loadOccupancy(), 0);
    if (!supabase) return () => window.clearTimeout(initial);
    const client = supabase;
    let active = true;
    let channel: ReturnType<typeof client.channel> | null = null;
    const poll = window.setInterval(() => void loadOccupancy(), 45_000);
    const onVisibility = () => {
      if (document.visibilityState === "visible") void loadOccupancy();
    };
    const { data: authListener } = client.auth.onAuthStateChange((_event, session) => {
      if (session?.access_token) void client.realtime.setAuth(session.access_token);
    });
    const refresh = () => void loadOccupancy();

    async function subscribe() {
      const { data: { session } } = await client.auth.getSession();
      if (!active || !session?.access_token) return;
      await client.realtime.setAuth(session.access_token);
      channel = client
        .channel(`staff-timetable:${from}:${to}`)
        .on("postgres_changes", { event: "*", schema: "public", table: "bookings" }, refresh)
        .on("postgres_changes", { event: "*", schema: "public", table: "booking_slots" }, refresh)
        .subscribe((status) => {
          if (status === "SUBSCRIBED") {
            setSyncError("");
            return;
          }
          if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
            setSyncError("实时占用同步暂时中断，系统会继续自动刷新。");
          }
        });
    }

    document.addEventListener("visibilitychange", onVisibility);
    void subscribe();

    return () => {
      active = false;
      authListener.subscription.unsubscribe();
      document.removeEventListener("visibilitychange", onVisibility);
      window.clearTimeout(initial);
      window.clearInterval(poll);
      if (channel) void client.removeChannel(channel);
    };
  }, [from, loadOccupancy, supabase, to]);

  useEffect(() => {
    const initial = window.setTimeout(() => setNow(Date.now()), 0);
    const id = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => { window.clearTimeout(initial); window.clearInterval(id); };
  }, []);

  async function loadSlotBookings(date: string, hour: number) {
    if (!supabase) return [];
    const slotStart = `${String(hour).padStart(2, "0")}:00:00`;
    const { data, error } = await supabase
      .from("booking_slots")
      .select(`booking_date,slot_start,bookings(${bookingSelect})`)
      .eq("booking_date", date)
      .eq("slot_start", slotStart);
    if (error) {
      setSyncError(error.message);
      return [];
    }
    const unique = new Map<string, Booking>();
    for (const row of (data ?? []) as Array<{ bookings: Booking | Booking[] | null }>) {
      const related = Array.isArray(row.bookings) ? row.bookings : row.bookings ? [row.bookings] : [];
      for (const booking of related) {
        const active =
          booking.status === "CONFIRMED" ||
          (booking.status === "HOLD" &&
            !!booking.hold_expires_at &&
            new Date(booking.hold_expires_at).getTime() > Date.now());
        if (active) unique.set(booking.id, booking);
      }
    }
    return [...unique.values()];
  }

  function cell(date: string, hour: number) {
    const slotStart = `${String(hour).padStart(2, "0")}:00:00`;
    const row = occupancy.find((item) => item.booking_date === date && item.slot_start === slotStart);
    const normalGroups = row?.normal_groups ?? 0;
    const hasPrivate = row?.has_private ?? false;
    const occupied = hasPrivate || normalGroups > 0;
    if (hasPrivate) return { occupied, text: "包场", sub: "已满", cls: "occ-private" };
    if (normalGroups >= 2) return { occupied, text: "2/2", sub: "已满", cls: "occ-full" };
    if (normalGroups === 1) return { occupied, text: "1/2", sub: "剩1组", cls: "occ-one" };
    return { occupied, text: "0/2", sub: "可约", cls: "occ-open" };
  }

  async function openSlot(date: string, hour: number) {
    const info = cell(date, hour);
    if (!info.occupied) return;
    setSelectedBooking(null);
    setSelectedLoading(true);
    setSelectedSlot({ date, hour, bookings: [], label: info.text });
    const bookings = await loadSlotBookings(date, hour);
    setSelectedSlot({ date, hour, bookings, label: info.text });
    setSelectedLoading(false);
  }

  return <main className="princess-shell min-h-screen px-4 py-5">
    <div className="mx-auto max-w-6xl">
      <header className="flex items-center justify-between"><Brand /><span className="rounded-full bg-white/70 px-3 py-1.5 text-xs text-[var(--muted)]">店员时段一览</span></header>
      <div className="mt-8 flex flex-wrap items-end justify-between gap-4">
        <div><h1 className="text-3xl font-black tracking-tight">预约时间表</h1><p className="mt-1 text-sm muted">快速查看每小时预约占用情况</p></div>
        <div className="segmented"><button className={view === "today" ? "active" : ""} onClick={() => setView("today")}>今日</button><button className={view === "week" ? "active" : ""} onClick={() => setView("week")}>本周</button></div>
      </div>
      <div className="mt-5 flex flex-wrap items-center gap-2">
        <button aria-label="上一段" className="mini-btn" onClick={() => setAnchor(addDays(anchor, view === "today" ? -1 : -7))}><ChevronLeft /></button>
        <button className="mini-btn !px-4" onClick={() => setAnchor(new Date())}>{view === "today" ? "今天" : "本周"}</button>
        <button aria-label="下一段" className="mini-btn" onClick={() => setAnchor(addDays(anchor, view === "today" ? 1 : 7))}><ChevronRight /></button>
        <b className="ml-2 text-sm">{view === "today" ? format(anchor, "M月d日 EEEE", { locale: zhCN }) : `${format(days[0], "M月d日")} – ${format(days[6], "M月d日")}`}</b>
        <button type="button" className="mini-btn !px-4" onClick={() => void loadOccupancy()} disabled={refreshing}>{refreshing ? "刷新中…" : "刷新"}</button>
      </div>
      {!supabase && <p className="mt-4 rounded-2xl bg-white p-4 text-sm text-rose-700">尚未连接预约数据库</p>}
      {!!syncError && <p className="mt-4 rounded-2xl bg-white p-4 text-sm text-amber-700">{syncError}</p>}

      {view === "today" ? <div className="mt-5 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 15 }, (_, i) => i + 9).map(hour => {
          const info = cell(format(anchor, "yyyy-MM-dd"), hour);
          const occupied = info.occupied;
          return <button type="button" disabled={!occupied} onClick={() => openSlot(format(anchor, "yyyy-MM-dd"), hour)} className={`occ-card text-left ${info.cls} ${occupied ? "cursor-pointer" : "cursor-default"}`} key={hour}>
            <span className="text-sm font-bold">{hourLabel(hour)}</span><b className="text-xl">{info.text}</b><span className="text-xs">{info.sub}</span>
          </button>;
        })}
      </div> : <div className="timetable-wrap mt-5"><table className="w-full min-w-[780px] border-separate border-spacing-1.5 text-center text-xs">
        <thead><tr><th className="p-2 text-left muted">时间</th>{days.map(day => <th className="p-2" key={day.toString()}>{format(day, "EEE", { locale: zhCN })}<span className="ml-1 font-normal muted">{format(day, "M/d")}</span></th>)}</tr></thead>
        <tbody>{Array.from({ length: 15 }, (_, i) => i + 9).map(hour => <tr key={hour}><th className="whitespace-nowrap p-2 text-left font-medium muted">{String(hour).padStart(2, "0")}–{hour + 1}</th>{days.map(day => {
          const date = format(day, "yyyy-MM-dd");
          const info = cell(date, hour);
          return <td key={day.toString()}><button type="button" disabled={!info.occupied} onClick={() => openSlot(date, hour)} className={`w-full rounded-xl px-2 py-2.5 ${info.cls} ${info.occupied ? "cursor-pointer" : "cursor-default"}`}><b>{info.text}</b></button></td>;
        })}</tr>)}</tbody>
      </table></div>}

      <div className="mt-5 flex flex-wrap gap-4 text-xs muted"><span><i className="legend occ-open" />可约</span><span><i className="legend occ-one" />剩1组</span><span><i className="legend occ-full" />已满</span><span><i className="legend occ-private" />包场</span></div>
    </div>

    {selectedSlot && <SlotDrawer slot={selectedSlot} now={now} booking={selectedBooking} loading={selectedLoading} onBooking={setSelectedBooking} onClose={() => { setSelectedBooking(null); setSelectedSlot(null); setSelectedLoading(false); }} />}
  </main>;
}

function SlotDrawer({ slot, now, booking, loading, onBooking, onClose }: { slot: SelectedSlot; now: number; booking: Booking | null; loading: boolean; onBooking: (booking: Booking | null) => void; onClose: () => void }) {
  return <div className="fixed inset-0 z-30 grid place-items-end bg-[#68445255] sm:place-items-center sm:p-5" onClick={onClose}>
    <div role="dialog" aria-modal="true" aria-label="预约时段详情" className="max-h-[88vh] w-full max-w-lg overflow-y-auto rounded-t-3xl bg-white p-6 sm:rounded-3xl" onClick={event => event.stopPropagation()}>
      <div className="flex items-start justify-between gap-4"><div><h2 className="text-xl font-black">{formatLocalDate(slot.date)}</h2><p className="mt-1 text-sm muted">{hourLabel(slot.hour)} · {slot.label === "包场" ? "包场" : `已预约 ${slot.label}`}</p></div><button type="button" aria-label="关闭" onClick={onClose}><X /></button></div>
      {booking ? <BookingDetail booking={booking} now={now} onBack={() => onBooking(null)} /> : loading ? <p className="mt-5 text-sm muted">正在同步该时段预约明细…</p> : <div className="mt-5 space-y-3">{slot.bookings.map(item => <button type="button" className="w-full rounded-2xl border border-[var(--line)] p-4 text-left" key={item.id} onClick={() => onBooking(item)}>
        <b className="text-[var(--rose)]">{item.booking_number}</b>
        <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm"><dt className="muted">客户</dt><dd>{item.customer_name}</dd><dt className="muted">项目</dt><dd>{projectLabel(item)}</dd><dt className="muted">完整预约时间</dt><dd>{timeRange(item)}</dd><dt className="muted">状态</dt><dd>{statusText(item, now)}</dd></dl>
      </button>)}</div>}
    </div>
  </div>;
}

function BookingDetail({ booking, now, onBack }: { booking: Booking; now: number; onBack: () => void }) {
  const rows = [
    ["预约编号", booking.booking_number], ["客户姓名 / 昵称", booking.customer_name], ["联系方式", booking.contact], ["预约日期", formatLocalDate(booking.booking_date)],
    ["完整预约时间", timeRange(booking)], ["预约项目", typeLabels[booking.booking_type]], ["陪同人数", `${booking.companion_count} 人`], ["相机需求", booking.camera_preference || "不需要"],
    ["预约总价", money(booking.final_price)], ["应收定金", money(booking.deposit_due)], ["实际已付定金", money(booking.deposit_paid)], ["到店待付", money(booking.balance_due)],
    ["预约状态", statusText(booking, now)], ["预约来源", sourceLabels[booking.booking_source] ?? booking.booking_source], ["顾客备注", booking.notes || "无"], ["店员备注", booking.staff_notes || "无"],
  ];
  return <div className="mt-5"><button type="button" className="text-sm font-bold text-[var(--rose)]" onClick={onBack}>← 返回时段预约</button><dl className="mt-5 space-y-4">{rows.map(([label, value]) => <div key={label}><dt className="text-xs muted">{label}</dt><dd className="mt-1 whitespace-pre-wrap font-medium">{value}</dd></div>)}</dl></div>;
}

function statusText(booking: Booking, now: number) {
  if (booking.status === "HOLD" && booking.hold_expires_at) {
    const seconds = Math.max(0, Math.floor((new Date(booking.hold_expires_at).getTime() - now) / 1_000));
    return `${statusLabels.HOLD} · 剩余 ${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  }
  return statusLabels[booking.status] ?? booking.status;
}
function projectLabel(booking: Booking) { return `${typeLabels[booking.booking_type]}${booking.companion_count ? ` + ${booking.companion_count}陪` : ""}`; }
function timeRange(booking: Booking) { return `${booking.start_time.slice(0, 5)}–${booking.end_time.slice(0, 5)}`; }
function hourLabel(hour: number) { return `${String(hour).padStart(2, "0")}:00–${hour + 1 === 24 ? "24" : String(hour + 1).padStart(2, "0")}:00`; }
function formatLocalDate(date: string) { const [year, month, day] = date.split("-"); return `${year}年${Number(month)}月${Number(day)}日`; }
