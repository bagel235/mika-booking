"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle2, Clock3, XCircle } from "lucide-react";
import { Brand } from "@/components/brand";
import { createClient } from "@/lib/supabase/client";
import { money, statusLabels, typeLabels } from "@/lib/booking";

type Summary = {
  booking_number: string;
  booking_date: string;
  start_time: string;
  end_time: string;
  booking_type: keyof typeof typeLabels;
  companion_count: number;
  camera_preference: string | null;
  final_price: number;
  deposit_due: number;
  deposit_paid: number;
  balance_due: number;
  status: string;
  hold_expires_at: string | null;
  payment_instructions: string | null;
  payment_qr_url: string | null;
};

const notices = [
  "本摄影棚实行预约制，预约定金为订单总价的50%。",
  "店内设有化妆、换衣区域，可以提前到店更换服装。",
  "因个人原因迟到，原则上仍按原预约结束时间计算；如需调整，以店员现场安排为准。",
  "店内设施、服装、道具及相机请妥善使用。如因人为原因造成破损或丢失，需按实际成本承担赔付责任。",
];
const cancellationRules = [
  "定金支付前：可在预约页面自主取消，取消后时段立即释放。",
  "定金支付后：顾客无法在线自行取消或改期，如有需要请联系店员处理。",
  "因顾客个人原因迟到或取消，已支付定金不予退还。",
  "临时预约需在15分钟内完成定金确认；逾期未确认的预约将自动失效，预约时段重新开放。",
];
const cleaningRules = [
  "拍摄结束后，请将使用过的服装、道具及可移动物品尽量放回原处。",
  "请将个人垃圾投入指定垃圾桶，并随身带走个人物品。",
  "使用化妆区、换衣区后，请保持台面及地面基本整洁。",
  "如不慎打翻饮品、弄脏布景、服装或其他设施，请及时告知店员，不要自行使用不明清洁剂处理。",
  "未经店员确认，请勿在墙面、布景或家具上使用可能留下痕迹的胶带、颜料、亮片等材料。",
  "如因明显超出正常使用范围的污损、破坏或遗留物产生额外清洁、修复费用，将根据实际情况另行确认。",
];

export function Confirmation({ token }: { token: string }) {
  const supabase = useMemo(() => createClient(), []);
  const [data, setData] = useState<Summary | null | undefined>();
  const [left, setLeft] = useState(0);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const [cancelError, setCancelError] = useState("");

  const load = useCallback(async () => {
    if (!supabase) return;
    const { data: rows } = await supabase.rpc("public_booking_summary", { p_token: token });
    setData((rows?.[0] as Summary | undefined) ?? null);
  }, [supabase, token]);

  useEffect(() => {
    const initial = window.setTimeout(() => void load(), 0);
    const id = window.setInterval(() => void load(), 4_000);
    const refreshVisible = () => { if (document.visibilityState === "visible") void load(); };
    document.addEventListener("visibilitychange", refreshVisible);
    return () => { window.clearTimeout(initial); window.clearInterval(id); document.removeEventListener("visibilitychange", refreshVisible); };
  }, [load]);

  useEffect(() => {
    if (!data?.hold_expires_at) return;
    const tick = () => setLeft(Math.max(0, Math.floor((new Date(data.hold_expires_at!).getTime() - Date.now()) / 1000)));
    tick();
    const id = window.setInterval(tick, 1_000);
    return () => window.clearInterval(id);
  }, [data?.hold_expires_at]);

  async function cancelHold() {
    if (!supabase) return;
    setCancelling(true);
    setCancelError("");
    const { data: cancelled, error } = await supabase.rpc("cancel_booking_by_token", { p_token: token });
    if (error || !cancelled) {
      setCancelError("未能取消预约。预约状态可能已经更新，请刷新后重试或联系店员。");
      await load();
      setCancelling(false);
      return;
    }
    setCancelOpen(false);
    setCancelling(false);
    await load();
  }

  if (!supabase) return <Empty text="尚未连接 Supabase，请完成环境配置。" />;
  if (data === undefined) return <Empty text="正在读取预约…" />;
  if (!data) return <Empty text="找不到这笔预约，链接可能无效。" />;

  const expired = data.status === "EXPIRED" || (data.status === "HOLD" && left <= 0);
  const active = data.status === "HOLD" && !expired;
  const confirmed = data.status === "CONFIRMED";
  const completed = data.status === "COMPLETED";
  const cancelled = data.status === "CANCELLED";
  const rescheduled = data.status === "RESCHEDULED";
  const title = expired ? "预约锁定已过期" : cancelled ? "预约已取消" : rescheduled ? "预约已改期" : completed ? "预约已完成" : active ? "预约已临时锁定" : "预约成功";
  const subtitle = expired ? "该时段已重新开放，请重新预约。" : cancelled ? "该预约已取消，当前时段已释放。" : rescheduled ? "预约信息已由店员调整，请联系店员确认最新安排。" : completed ? "感谢你来到 MIKA，期待再次见面。" : active ? "请在 15 分钟内完成定金支付。" : "MIKA 预约确认单";

  return <main className="shell min-h-screen px-5 py-6">
    <div className="mx-auto max-w-2xl">
      <Brand />
      <div className="card mt-10 p-6 md:p-10">
        <div className={`mx-auto flex h-16 w-16 items-center justify-center rounded-full ${expired || cancelled ? "bg-red-50 text-red-500" : active ? "bg-amber-50 text-amber-600" : "bg-emerald-50 text-emerald-600"}`}>
          {expired || cancelled ? <XCircle /> : active ? <Clock3 /> : <CheckCircle2 />}
        </div>
        <h1 className="mt-5 text-center text-3xl font-black">{title}</h1>
        <p className="mt-2 text-center muted">{subtitle}</p>

        {active && <div className="mt-6 rounded-2xl bg-[var(--ink)] p-5 text-center text-white">
          <p className="text-xs tracking-widest text-white/60">剩余时间</p>
          <p className="mt-1 font-mono text-4xl font-black">{String(Math.floor(left / 60)).padStart(2, "0")}:{String(left % 60).padStart(2, "0")}</p>
        </div>}

        <BookingDetails data={data} showPayment={confirmed || completed} status={expired ? "EXPIRED" : data.status} />

        {active && <div className="mt-7 rounded-2xl border border-[var(--line)] p-5">
          <h2 className="font-black">支付定金</h2>
          {data.payment_qr_url && <img src={data.payment_qr_url} alt="定金支付二维码" className="mx-auto mt-4 max-h-52 rounded-xl" />}
          <p className="mt-3 whitespace-pre-wrap text-sm leading-6 muted">{data.payment_instructions}</p>
          <p className="mt-2 text-xs muted">付款后由店员人工确认，本页面会自动更新预约状态。</p>
        </div>}

        {(confirmed || completed) && <>
          {confirmed && <p className="mt-7 rounded-2xl bg-emerald-50 p-4 text-sm leading-6 text-emerald-900">定金已确认。如需取消或改期，请联系店员处理。</p>}
          <PolicySection title="到店须知" items={notices} />
          <PolicySection title="取消与改期" items={cancellationRules} />
          <PolicySection title="使用及清洁规则" items={cleaningRules} />
          <div className="mt-8 border-t border-[var(--line)] pt-6 text-center text-sm leading-7 muted">
            <p>请妥善保存本预约编号。</p><p>到店时可向店员出示本页面。</p><p className="mt-2 font-bold text-[var(--ink)]">期待与你在 MIKA 见面 ♡</p>
          </div>
        </>}

        {active && <button type="button" className="btn mt-5 w-full border border-[var(--line)] bg-white" onClick={() => setCancelOpen(true)}>取消预约</button>}
        {(expired || cancelled) && <Link className="btn btn-primary mt-7 block text-center no-underline" href="/book">重新预约</Link>}
      </div>
    </div>

    {cancelOpen && <div className="fixed inset-0 z-50 grid place-items-center bg-black/45 px-5" role="dialog" aria-modal="true" aria-labelledby="cancel-title">
      <div className="card w-full max-w-md p-6">
        <h2 id="cancel-title" className="text-xl font-black">确认取消预约？</h2>
        <p className="mt-3 text-sm leading-6 muted">取消后，该时段会立即释放，且无法恢复。你确定要取消这笔预约吗？</p>
        {cancelError && <p className="mt-3 text-sm text-red-600" role="alert">{cancelError}</p>}
        <div className="mt-6 grid grid-cols-2 gap-3">
          <button type="button" className="btn border border-[var(--line)] bg-white" disabled={cancelling} onClick={() => setCancelOpen(false)}>暂不取消</button>
          <button type="button" className="btn bg-red-600 text-white" disabled={cancelling} onClick={() => void cancelHold()}>{cancelling ? "正在取消…" : "确认取消"}</button>
        </div>
      </div>
    </div>}
  </main>;
}

function BookingDetails({ data, showPayment, status }: { data: Summary; showPayment: boolean; status: string }) {
  const rows = [
    ["预约编号", data.booking_number],
    ["日期", data.booking_date],
    ["时间", `${data.start_time.slice(0, 5)}–${data.end_time.slice(0, 5)}`],
    ["项目", typeLabels[data.booking_type]],
    ["同行人数", `${data.companion_count} 人`],
    ["相机", data.camera_preference || "不需要"],
    ["总价", money(data.final_price)],
    [showPayment ? "定金已付" : "应付定金", money(showPayment ? data.deposit_paid : data.deposit_due)],
    ...(showPayment ? [["到店应付", money(data.balance_due)]] : []),
    ["状态", statusLabels[status] ?? status],
  ];
  return <dl className="mt-7 grid grid-cols-2 gap-y-4 text-sm">{rows.map(([label, value]) => <div className="contents" key={label}><dt className="muted">{label}</dt><dd className="text-right font-bold">{value}</dd></div>)}</dl>;
}

function PolicySection({ title, items }: { title: string; items: string[] }) {
  return <section className="mt-7"><h2 className="font-black">{title}</h2><ul className="mt-3 space-y-2 text-sm leading-6 muted">{items.map(item => <li key={item}>• {item}</li>)}</ul></section>;
}

function Empty({ text }: { text: string }) {
  return <main className="shell grid min-h-screen place-items-center px-5"><div className="card p-10 text-center"><p>{text}</p><Link href="/book" className="mt-5 inline-block text-sm font-bold text-[var(--orange)]">返回预约</Link></div></main>;
}
