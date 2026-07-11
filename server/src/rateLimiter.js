export class SlidingWindowRateLimiter {
  constructor(limit, windowMs) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.timestamps = [];
  }

  allow(now = Date.now()) {
    const minTime = now - this.windowMs;
    while (this.timestamps.length > 0 && this.timestamps[0] < minTime) {
      this.timestamps.shift();
    }

    if (this.timestamps.length >= this.limit) {
      return false;
    }

    this.timestamps.push(now);
    return true;
  }
}
