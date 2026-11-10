import { describe, expect, it } from "vitest";
import {
  comparableTrash,
  decideDeletion,
  deletionReason,
  deletionShare,
  senderAddress,
  trashMatches,
  type DeletionEvidence,
} from "../../../src/suggest/deletion.js";

const rules = { override: { share: 0.75, minExamples: 3 }, noFitShare: 0.5 };

function evidence(
  deleted: [number, number],
  trash: [number, number] = [0, 0],
  filedVote = 0,
): DeletionEvidence {
  return {
    deleted: { vote: deleted[0], count: deleted[1] },
    trash: { vote: trash[0], count: trash[1] },
    filedVote,
  };
}

const v = (...xs: number[]) => {
  const n = Math.hypot(...xs);
  return Float32Array.from(xs.map((x) => x / n));
};

describe("decideDeletion", () => {
  it("never suggests deletion without evidence, however badly the labels fit", () => {
    expect(decideDeletion(evidence([0, 0]), true, rules)).toBeNull();
    expect(decideDeletion(evidence([0, 0], [0, 0], 3), true, rules)).toBeNull();
  });

  it("suggests deletion when it is the owner's habit, even if a label fits", () => {
    const verdict = decideDeletion(evidence([3, 3], [0, 0], 0.9), false, rules);
    expect(verdict?.confidence).toBe("medium");
    expect(verdict?.reason).toBe("You deleted 3 similar emails before.");
  });

  it("is sure when it is a habit and no label fits", () => {
    expect(decideDeletion(evidence([3, 3]), true, rules)?.confidence).toBe("high");
  });

  it("needs as many examples as the override of the model when a label fits", () => {
    expect(decideDeletion(evidence([2, 2]), false, rules)).toBeNull();
    expect(decideDeletion(evidence([2, 2], [1, 1]), false, rules)).not.toBeNull();
  });

  it("needs the habit share when a label fits", () => {
    // 3 deleted against 1.5 filed: two thirds, below 0.75.
    expect(decideDeletion(evidence([3, 3], [0, 0], 1.5), false, rules)).toBeNull();
  });

  it("when no label fits, one similar deleted or trashed email is enough", () => {
    const one = decideDeletion(evidence([0, 0], [0.9, 1]), true, rules);
    expect(one?.confidence).toBe("low");
    expect(one?.reason).toBe(
      "No label fits well. 1 similar email from this sender is in the Trash.",
    );
  });

  it("when no label fits, deletion still has to be at least the noFitShare", () => {
    expect(decideDeletion(evidence([0.9, 1], [0, 0], 1), true, rules)).toBeNull();
    expect(decideDeletion(evidence([1, 1], [0, 0], 1), true, rules)?.confidence).toBe("low");
  });

  it("when no label fits and there are enough examples, it is medium", () => {
    expect(decideDeletion(evidence([1.4, 2], [0.8, 1], 1), true, rules)?.confidence).toBe("medium");
  });
});

describe("deletionShare and deletionReason", () => {
  it("is the share of the weighted evidence", () => {
    expect(deletionShare(evidence([0, 0]))).toBe(0);
    expect(deletionShare(evidence([1, 1], [1, 1], 2))).toBeCloseTo(0.5);
  });

  it("names both sources of evidence", () => {
    expect(deletionReason(evidence([1, 1], [2, 2]), false)).toBe(
      "You deleted 1 similar email before, and 2 from this sender are in the Trash.",
    );
    expect(deletionReason(evidence([0, 0], [2, 2]), true)).toBe(
      "No label fits well. 2 similar emails from this sender are in the Trash.",
    );
  });
});

describe("Trash evidence", () => {
  it("compares senders by address, ignoring names and case", () => {
    expect(senderAddress("Shop News <News@Shop.example.test>")).toBe("news@shop.example.test");
    expect(senderAddress("news@shop.example.test")).toBe("news@shop.example.test");
    expect(senderAddress('"Shop" news@shop.example.test')).toBe("news@shop.example.test");
    expect(senderAddress("Just A Name")).toBe("just a name");
  });

  it("only compares trashed emails from the same sender, with a subject", () => {
    const email = { from: "Shop <news@shop.example.test>", subject: "Weekly deals" };
    const trash = [
      { from: "news@shop.example.test", subject: "Weekly deals again" },
      { from: "Other <other@shop.example.test>", subject: "Weekly deals" },
      { from: "Shop <NEWS@shop.example.test>", subject: "  " },
    ];
    expect(comparableTrash(email, trash)).toEqual([trash[0]]);
    expect(comparableTrash({ ...email, subject: "" }, trash)).toEqual([]);
  });

  it("counts the most similar subjects above the threshold, at most the limit", () => {
    const subject = v(1, 0);
    const trashed = [v(1, 0), v(1, 0.1), v(0, 1), v(1, 0.2)];
    expect(trashMatches(subject, trashed, 0.9, 8).count).toBe(3);
    const two = trashMatches(subject, trashed, 0.9, 2);
    expect(two.count).toBe(2);
    expect(two.vote).toBeCloseTo(1 + Math.cos(Math.atan(0.1)));
    expect(trashMatches(undefined, trashed, 0.9, 8).count).toBe(0);
  });
});
