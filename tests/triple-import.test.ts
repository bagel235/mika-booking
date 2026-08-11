import test from "node:test";
import assert from "node:assert/strict";
import { bookingTypes, typeLabels } from "../lib/booking.ts";

test("CSV booking type validation accepts TRIPLE",()=>{
  assert.equal(bookingTypes.includes("TRIPLE"),true);
  assert.equal(typeLabels.TRIPLE,"三人");
});

test("CSV booking type validation still rejects unknown values",()=>{
  assert.equal((bookingTypes as readonly string[]).includes("QUADRUPLE"),false);
});
