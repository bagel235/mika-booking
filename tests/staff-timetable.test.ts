import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const page = readFileSync("app/timetable/page.tsx", "utf8");
const timetable = readFileSync("app/timetable/timetable.tsx", "utf8");

test("timetable requires a verified user and staff profile", () => {
  assert.match(page, /auth\.getUser\(\)/);
  assert.match(page, /from\("profiles"\)/);
  assert.match(page, /redirect\("\/admin"\)/);
});

test("timetable loads occupancy from the authoritative aggregate and keeps booking details staff-only", () => {
  assert.match(timetable, /rpc\("public_slot_occupancy"/);
  assert.match(timetable, /from\("booking_slots"\)/);
  assert.doesNotMatch(timetable, /public_access_token/);
  assert.match(timetable, /booking\.status === "CONFIRMED"/);
  assert.match(timetable, /booking\.status === "HOLD"/);
  assert.match(timetable, /const loadOccupancy = useCallback/);
});

test("timetable stays live through realtime, polling, and manual refresh", () => {
  assert.match(timetable, /table: "bookings"/);
  assert.match(timetable, /table: "booking_slots"/);
  assert.match(timetable, /event: "\*"/);
  assert.match(timetable, /setInterval\(\(\) => void loadOccupancy\(\), 45_000\)/);
  assert.match(timetable, /刷新中…/);
  assert.match(timetable, /: "刷新"/);
  assert.match(timetable, /realtime\.setAuth\(session\.access_token\)/);
});

test("occupied cells and booking details expose the requested staff fields", () => {
  assert.match(timetable, /new Map<string, Booking>/);
  for (const label of ["完整预约时间", "预约编号", "客户姓名 \\/ 昵称", "联系方式", "预约总价", "应收定金", "实际已付定金", "到店待付", "预约来源", "顾客备注", "店员备注"]) {
    assert.match(timetable, new RegExp(label));
  }
});

test("today and week occupancy views remain intact", () => {
  for (const label of ["今日", "本周", "0/2", "1/2", "2/2", "包场"]) assert.match(timetable, new RegExp(label));
});
