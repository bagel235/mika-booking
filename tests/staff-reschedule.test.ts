import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const admin = readFileSync("app/admin/bookings/bookings.tsx", "utf8");
const timetable = readFileSync("app/timetable/timetable.tsx", "utf8");
const confirmation = readFileSync("app/book/confirmation/[token]/confirmation.tsx", "utf8");
const wizard = readFileSync("app/book/wizard.tsx", "utf8");
const migration = readFileSync("supabase/migrations/20260811061137_staff_notes_and_deposit_reschedule.sql", "utf8");

test("staff can edit private notes without exposing them to customers", () => {
  assert.match(admin, /店员备注/);
  assert.match(admin, /保存备注/);
  assert.match(admin, /update\(\{ staff_notes:/);
  assert.match(timetable, /staff_notes/);
  assert.doesNotMatch(confirmation, /staff_notes/);
  assert.match(wizard, /预约备注（选填）/);
  assert.match(wizard, /p_notes:notes\.trim\(\)\|\|null/);
});

test("confirmed booking reschedule requires a price preview", () => {
  assert.match(admin, /booking\.status === "CONFIRMED"/);
  assert.match(admin, /预览改期/);
  assert.match(admin, /原预约时间/);
  assert.match(admin, /新预约时间/);
  assert.match(admin, /已付定金/);
  assert.match(admin, /改期后待付金额/);
  assert.match(admin, /已付金额高于改期后订单金额，请人工处理差额/);
});

test("migration performs in-place atomic slot transfer and retains deposit", () => {
  assert.match(migration, /for update/);
  assert.match(migration, /and b\.id<>old\.id/);
  assert.match(migration, /delete from booking_slots where booking_id=old\.id/);
  assert.match(migration, /update bookings/);
  assert.doesNotMatch(migration, /deposit_paid\s*=/);
  assert.doesNotMatch(migration, /booking_number\s*=/);
  assert.match(migration, /status='CONFIRMED'/);
});

test("reschedule history records pricing, schedule, staff, deposit, and reason", () => {
  for (const field of ["new_booking_date", "new_start_time", "new_standard_price", "new_price_adjustment", "retained_deposit_paid", "reason", "changed_by"]) assert.match(migration, new RegExp(field));
});
