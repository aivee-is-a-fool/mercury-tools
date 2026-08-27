#!/usr/bin/env python3
"""check-site.py — walk a PUBLISHED site and answer two questions that a reader
would otherwise answer for us:

  1. Does every internal link and asset on the site actually resolve?
  2. Do the URLs we have decided must NOT be served stay unserved?

WHY IT WALKS THE BUILT SITE AND NOT THE REPOSITORY. @mercury-girl's case on the
site repo is the whole argument: two Markdown files sitting at the repo root
were being served as /AGENTS, /AGENTS.html and /AGENTS.md. A checker reading the
source tree would have found no such pages and reported clean. The built site
and the source tree are different sets of paths, and only one of them is what a
reader can reach.

WHY QUESTION 2 EXISTS. Every instrument we have written so far confirms what the
system DOES and nothing about what it REFUSES, and a negative claim is not
verified by reading the rule that states it. An `exclude:` list is such a rule.
--must-404 turns it into a check that can fail.

WHY PYTHON AND NOT BASH, in a repo that is otherwise bash. Extracting links with
a regex is the wrong tool and breaks on a multi-line attribute or a tag inside a
comment. html.parser is in the standard library: no packages, no install. If
python3 is missing this script says so and exits 2 rather than half-working.

RATE LIMIT. A published site is somebody's shared host, and the standing rule is
one request per second per host. That floor is enforced here and cannot be set
lower -- a crawler is precisely the thing that forgets.

Usage:
  check-site.py <base-url> [--must-404 URL_OR_PATH]... [--delay SECONDS]
                           [--max-pages N] [--quiet]

  check-site.py https://example.github.io/ \
      --must-404 /AGENTS --must-404 /AGENTS.md --must-404 /CLAUDE

Exit 0 = everything resolved and every must-404 stayed unserved.
Exit 1 = a FINDING about the site: a broken target, or a must-404 URL that answered.
Exit 2 = this script could not do its job (bad usage, unreachable base, or a
         request that failed outright). Kept separate from 1 on purpose: a
         request that never completed is the INSTRUMENT failing, and reporting
         that as a finding about the site is how a broken checker passes for a
         working one.
"""

import sys
import time
import argparse
from collections import deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

MIN_DELAY = 1.0          # standing rule: 1 req/sec per host. Not negotiable.
USER_AGENT = "mercury-tools check-site (link and asset check for our own site)"
SKIP_SCHEMES = ("mailto:", "tel:", "javascript:", "data:", "#")

# tag -> the attribute that carries a URL we care about.
URL_ATTRS = {
    "a": "href",
    "img": "src",
    "link": "href",
    "script": "src",
    "source": "src",
    "iframe": "src",
    "video": "src",
    "audio": "src",
}

# What this checker does NOT look at. Named here because an instrument that does
# not state its blind spots gets read as covering everything.
UNCHECKED = [
    "srcset attributes (responsive images)",
    "url(...) targets inside CSS files or style attributes",
    "anything a page builds with JavaScript at runtime",
    "whether a page that resolves contains the RIGHT CONTENT",
]


class LinkCollector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []

    def handle_starttag(self, tag, attrs):
        attr = URL_ATTRS.get(tag)
        if not attr:
            return
        url = dict(attrs).get(attr)
        if url:
            self.found.append((tag, url.strip()))


class Fetcher:
    """One request per host per delay seconds, and a memo so a URL linked from
    forty pages costs one request."""

    def __init__(self, delay):
        self.delay = max(delay, MIN_DELAY)
        self.last = {}
        self.memo = {}

    def _wait(self, host):
        prev = self.last.get(host)
        if prev is not None:
            gap = self.delay - (time.monotonic() - prev)
            if gap > 0:
                time.sleep(gap)
        self.last[host] = time.monotonic()

    def get(self, url, method="GET"):
        """Returns (status, content_type, body_or_None). status 0 means the
        request itself failed -- a DNS or TLS problem is not a 404 and must not
        be reported as one."""
        key = (method, url)
        if key in self.memo:
            return self.memo[key]
        self._wait(urlsplit(url).netloc)
        req = Request(url, method=method, headers={"User-Agent": USER_AGENT})
        try:
            with urlopen(req, timeout=30) as resp:
                ctype = resp.headers.get("Content-Type", "")
                body = resp.read() if method == "GET" else None
                out = (resp.status, ctype, body)
        except HTTPError as e:
            ctype = e.headers.get("Content-Type", "") if e.headers else ""
            out = (e.code, ctype, None)
        except (URLError, OSError) as e:
            out = (0, str(e), None)
        self.memo[key] = out
        return out


def normalise(url):
    """Drop the fragment, keep the query. Two links differing only by #anchor
    are one request."""
    p = urlsplit(url)
    return urlunsplit((p.scheme, p.netloc, p.path or "/", p.query, ""))


def same_site(url, root):
    a, b = urlsplit(url), urlsplit(root)
    return (a.scheme, a.netloc) == (b.scheme, b.netloc)


def resolve_must_404(item, base):
    """Turn a --must-404 argument into a URL, or raise ValueError saying why not.

    This exists because of a real failure on the first run. Under Git Bash on
    Windows, MSYS rewrites an argument that looks like a Unix path before the
    program is even started: `--must-404 /AGENTS` arrived here as an absolute
    Windows path pointing into the Git installation. The script dutifully tried
    to fetch it, failed, and printed six leaks that were not leaks. The argument
    was already corrupt one layer below the program, which is not a class of bug
    a program can fix -- only refuse to report as a finding.
    """
    if "\\" in item or (len(item) > 1 and item[1] == ":"):
        raise ValueError(
            "%r is a local filesystem path, not a URL. Under Git Bash, MSYS "
            "rewrites a leading-slash argument into a Windows path before this "
            "script runs. Pass the full URL, or prefix the command with "
            "MSYS_NO_PATHCONV=1." % item)
    parts = urlsplit(item)
    if parts.scheme in ("http", "https"):
        return normalise(item)
    if parts.scheme:
        raise ValueError("%r: unsupported scheme %r" % (item, parts.scheme))
    if not item.startswith("/"):
        raise ValueError("%r must be an absolute path (start with /) or a full URL" % item)
    return normalise(urljoin(base, item))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--must-404", action="append", default=[], metavar="URL",
                    help="URL or path that must NOT be served. Repeatable.")
    ap.add_argument("--delay", type=float, default=MIN_DELAY,
                    help="seconds between requests to one host (floor 1.0)")
    ap.add_argument("--max-pages", type=int, default=200,
                    help="stop after N pages; a runaway crawl on somebody's "
                         "host is worse than an incomplete report")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if urlsplit(args.base).scheme not in ("http", "https"):
        print("check-site: base must be an http(s) URL", file=sys.stderr)
        return 2
    base = normalise(args.base)

    # Resolve every must-404 argument BEFORE any request. A bad argument is a
    # usage error and must never reach the report as a site finding.
    try:
        must_404 = [resolve_must_404(i, base) for i in getattr(args, "must_404")]
    except ValueError as e:
        print("check-site: %s" % e, file=sys.stderr)
        return 2

    f = Fetcher(args.delay)
    say = (lambda *a: None) if args.quiet else (lambda *a: print(*a))

    # ---- question 1: does everything on the site resolve? ----
    queue = deque([base])
    seen_pages = set()
    page_status = {}
    broken = []       # findings about the site
    unproven = []     # requests that never completed: OUR failure, not the site's
    checked_assets = 0
    truncated = False

    while queue:
        if len(seen_pages) >= args.max_pages:
            truncated = True
            break
        page = queue.popleft()
        if page in seen_pages:
            continue
        seen_pages.add(page)

        status, ctype, body = f.get(page)
        page_status[page] = status
        if status != 200:
            if page == base:
                print("check-site: base URL answered %s -- nothing to walk"
                      % status, file=sys.stderr)
                return 2
            continue
        if "html" not in ctype.lower() or body is None:
            continue

        parser = LinkCollector()
        try:
            parser.feed(body.decode("utf-8", "replace"))
        except Exception as e:
            broken.append((page, "-", "(unparseable HTML)", str(e)))
            continue

        for tag, raw in parser.found:
            if raw.lower().startswith(SKIP_SCHEMES):
                continue
            target = normalise(urljoin(page, raw))
            if not same_site(target, base):
                continue          # someone else's host; not ours to poll
            if tag == "a":
                if target not in seen_pages:
                    queue.append(target)
                continue
            st, ctype, _ = f.get(target, method="HEAD")
            if st in (405, 501):  # host dislikes HEAD
                st, ctype, _ = f.get(target, method="GET")
            checked_assets += 1
            if st == 0:
                unproven.append((target, "request failed on %s: %s" % (page, ctype)))
            elif st != 200:
                broken.append((page, tag, target, st))

    for page, st in page_status.items():
        if page == base:
            continue
        if st == 0:
            unproven.append((page, "request failed; not evidence of a broken link"))
        elif st != 200:
            broken.append(("(a link on the site)", "a", page, st))

    # ---- question 2: do the refusals hold? ----
    leaked = []
    for url in must_404:
        st, ctype, _ = f.get(url, method="GET")
        if st == 0:
            unproven.append((url, "request failed: cannot prove it is unserved (%s)" % ctype))
        elif st != 404:
            leaked.append((url, "answered %s -- it is being served" % st))

    # ---- report ----
    say("check-site %s" % base)
    say("  pages walked   : %d%s"
        % (len(seen_pages), "  (TRUNCATED at --max-pages)" if truncated else ""))
    say("  assets checked : %d" % checked_assets)
    say("  must-404 tested: %d" % len(must_404))
    say("  NOT checked    : " + "; ".join(UNCHECKED))

    if broken:
        say("\nBROKEN (%d):" % len(broken))
        for ref, tag, target, st in broken:
            say("  %s  <%s> -> %s   on %s" % (st, tag, target, ref))
    if leaked:
        say("\nSERVED BUT MUST NOT BE (%d):" % len(leaked))
        for url, why in leaked:
            say("  %s   %s" % (url, why))
    if unproven:
        say("\nCOULD NOT ANSWER (%d) -- this checker failed here, the site is "
            "not accused:" % len(unproven))
        for url, why in unproven:
            say("  %s   %s" % (url, why))

    if broken or leaked:
        say("\nFAIL")
        return 1
    if unproven:
        say("\nINCONCLUSIVE")
        return 2
    if truncated:
        # Found while reflecting on this script an hour after writing it: the
        # first version returned 0 here with a caveat in the text. But "the
        # crawl stopped early" is the same statement as everything else on the
        # exit-2 side -- the checker did not answer the question it was asked --
        # and a 0 that a caller reads as OK is exactly the silent pass this tool
        # exists to prevent. A caveat a machine cannot see is not a caveat.
        say("\nINCONCLUSIVE -- crawl truncated at --max-pages; clean for what "
            "was walked, and that is not the whole site.")
        return 2
    say("\nOK")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
