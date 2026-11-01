import { describe, expect, it } from "vitest";
import {
  dedupeCandidates,
  normaliseName,
  parsePath,
  PathError,
  renderTree,
  validateName,
} from "../../../src/categories/path.js";

describe("category paths", () => {
  it("accepts one and two levels", () => {
    expect(parsePath("Family")).toEqual({ parent: null, name: "Family" });
    expect(parsePath(" Family / Baby ")).toEqual({ parent: "Family", name: "Baby" });
  });

  it("rejects more than two levels", () => {
    expect(() => parsePath("Family/Baby/Clothes")).toThrow(PathError);
  });

  it("rejects empty and over-long segments", () => {
    expect(() => parsePath("Family/")).toThrow(PathError);
    expect(() => parsePath("")).toThrow(PathError);
    expect(() => parsePath("x".repeat(61))).toThrow(PathError);
  });

  it("rejects '/' in a single name", () => {
    expect(() => validateName("A/B")).toThrow(PathError);
  });

  it("folds case, accents and whitespace", () => {
    expect(normaliseName("  Család  ")).toBe("csalad");
    expect(normaliseName("csalad")).toBe("csalad");
    expect(normaliseName("Trip   Lisbon")).toBe("trip lisbon");
  });

  it("de-duplicates case- and accent-insensitively, keeping first-seen casing", () => {
    const c = dedupeCandidates(["Család", "csalad", "Gadgets", "gadgets"]);
    expect(c.map((x) => x.path)).toEqual(["Család", "Gadgets"]);
  });

  it("adds implied parents before their first child", () => {
    const c = dedupeCandidates(["Travelling/TripXYZ", "Family"]);
    expect(c.map((x) => x.path)).toEqual(["Travelling", "Travelling/TripXYZ", "Family"]);
    expect(c[1]!.parentKey).toBe("travelling");
  });

  it("uses the parent's display casing for children", () => {
    const c = dedupeCandidates(["Family", "family/Baby"]);
    expect(c.map((x) => x.path)).toEqual(["Family", "Family/Baby"]);
  });

  it("renders an indented tree", () => {
    const tree = renderTree(dedupeCandidates(["Family", "Family/Baby", "Gadgets"]));
    expect(tree).toBe("- Family\n  - Family/Baby\n- Gadgets");
  });
});
