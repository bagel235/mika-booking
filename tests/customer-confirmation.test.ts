import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync("app/book/confirmation/[token]/confirmation.tsx", "utf8");

test("active holds expose secure customer cancellation with confirmation", () => {
  assert.match(source, /cancel_booking_by_token/);
  assert.match(source, /确认取消预约？/);
  assert.match(source, /取消后，该时段会立即释放，且无法恢复/);
  assert.match(source, /预约已临时锁定/);
});

test("confirmed view includes reference, payment, policies, and cleaning rules", () => {
  for (const text of ["MIKA 预约确认单", "预约编号", "定金已付", "到店应付", "到店须知", "取消与改期", "使用及清洁规则", "请妥善保存本预约编号"]) {
    assert.match(source, new RegExp(text));
  }
  assert.match(source, /deposit_paid/);
  assert.match(source, /balance_due/);
  assert.match(source, /不要自行使用不明清洁剂处理/);
});

test("public UI does not name the private database token field", () => {
  assert.doesNotMatch(source, /public_access_token/);
});

test("confirmation status is refreshed safely", () => {
  assert.match(source, /setInterval\(\(\) => void load\(\), 4_000\)/);
  assert.match(source, /visibilitychange/);
});
