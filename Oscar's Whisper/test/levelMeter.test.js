import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { LevelMeter, rmsToDb } from "../src/main/audio/levelMeter.js";

const dbToRms = (db) => 10 ** (db / 20);

describe("LevelMeter", () => {
  test("rmsToDb converts amplitude to decibels", () => {
    assert.ok(Math.abs(rmsToDb(1)) < 1e-6);
    assert.ok(Math.abs(rmsToDb(0.1) + 20) < 1e-6);
  });

  test("scales dB above the -60 dB floor over a 20 dB range, clamped to 0..1", () => {
    const meter = new LevelMeter();
    assert.ok(Math.abs(meter.push(dbToRms(-50)) - 0.5) < 1e-6);
    assert.equal(meter.push(dbToRms(-20)), 1);
  });

  test("the floor only moves down, to the quietest chunk seen", () => {
    const meter = new LevelMeter();
    assert.equal(meter.push(dbToRms(-80)), 0);
    assert.ok(Math.abs(meter.push(dbToRms(-70)) - 0.5) < 1e-6);
    meter.reset();
    assert.ok(Math.abs(meter.push(dbToRms(-50)) - 0.5) < 1e-6);
  });

  test("drain returns the mean since the last drain, then null when idle", () => {
    const meter = new LevelMeter();
    meter.push(dbToRms(-60));
    meter.push(dbToRms(-40));
    assert.ok(Math.abs(meter.drain() - 0.5) < 1e-6);
    assert.equal(meter.drain(), null);
  });
});
