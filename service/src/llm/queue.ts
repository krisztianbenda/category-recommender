/** Single-slot FIFO queue: one generation at a time on the 16 GB host (research R2). */
export class SerialQueue {
  private tail: Promise<unknown> = Promise.resolve();
  private waiting = 0;

  run<T>(task: () => Promise<T>): Promise<T> {
    this.waiting++;
    const result = this.tail.then(task, task);
    this.tail = result.then(
      () => this.waiting--,
      () => this.waiting--,
    );
    return result;
  }

  get pending(): number {
    return this.waiting;
  }
}
