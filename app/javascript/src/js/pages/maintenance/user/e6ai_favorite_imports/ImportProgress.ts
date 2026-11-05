export interface ImportProgressData {
  status: string;
  percent: number;
  found_count: number;
  expected_count: number | null;
}

const FINISHED = ["done", "failed", "none"];
// Logged out, forbidden or gone: polling again cannot help.
const STOP_STATUSES = [401, 403, 404];
const MAX_INTERVAL_MS = 30_000;

export function describeProgress (data: ImportProgressData): string {
  const n = (value: number) => value.toLocaleString("en-US");
  switch (data.status) {
    case "queued":
      return "Waiting to start…";
    case "fetching":
      return data.expected_count
        ? `Fetching from e6ai.net: ${n(data.found_count)} of ${n(data.expected_count)} favorites…`
        : `Fetching from e6ai.net: ${n(data.found_count)} favorites…`;
    case "saving":
      return `Saving ${n(data.found_count)} favorites…`;
    default:
      return "";
  }
}

// Loads the page fresh with GET, so a page that came from a form submission is never resubmitted.
const showFinished = () => window.location.assign(window.location.pathname);

// Polls the import's JSON while it runs and shows the finished page once it is done.
// Errors double the interval, up to 30 seconds; a success returns it to normal.
export function watchImportProgress (root: HTMLElement, intervalMs = 1000, finish = showFinished): () => void {
  const url = root.dataset.url;
  const bar = root.querySelector("progress");
  const label = root.querySelector(".e6ai-import-status");
  let timer: number | undefined;
  let stopped = false;
  let wait = intervalMs;

  const poll = async () => {
    if (stopped || !url) return;
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } });
      if (STOP_STATUSES.includes(response.status)) {
        stopped = true;
        return;
      }
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json() as ImportProgressData;
      if (FINISHED.includes(data.status)) {
        stopped = true;
        finish();
        return;
      }
      if (bar) bar.value = data.percent;
      if (label) label.textContent = describeProgress(data);
      wait = intervalMs;
    } catch {
      wait = Math.min(wait * 2, MAX_INTERVAL_MS);
    }
    if (!stopped) timer = window.setTimeout(poll, wait);
  };

  if (!FINISHED.includes(root.dataset.status ?? "")) timer = window.setTimeout(poll, intervalMs);
  return () => {
    stopped = true;
    window.clearTimeout(timer);
  };
}

$(() => {
  const root = document.getElementById("e6ai-import-progress");
  if (root) watchImportProgress(root);
});
