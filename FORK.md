> # ⚠️ This fork is retired (2026-11-19)
>
> **It was built on a false premise, and the premise is corrected below rather than deleted.**
>
> This fork was created on 2026-11-18 because upstream's published image looked abandoned:
> `2.1.3`, pushed 2026-06-17, appeared to be the newest tag on Docker Hub. It was not.
> **`2.2.0` and `latest` were pushed on 2026-11-17**, the day before this fork existed, multi-arch
> for amd64 and arm64, sharing index digest
> `sha256:9cb48e29722dcf35a7c84c95dddca7ce96c1fde516fb8b9b788d2a1d77aca39c`.
>
> The maintainer explained why it looked idle: the 2.2.0 work was on a test branch, which
> publishes to a separate test repository until it is merged. The mistake was on this side — a tag
> list read on 2026-10-22 was reused on 2026-11-18 as though it were current, without being
> measured again.
>
> **Upstream's `2.2.0` does the thing this fork was for.** The rebuild took `hplip` and
> `hplip-libs` to `3.26.6-r0`, the version that fixes `CVE-2026-91097` … `CVE-2026-91106` — all
> ten CRITICALs listed below. Measured 2026-11-19 with suppressions defeated, `2.2.0` reports
> `Total: 3 (HIGH: 3, CRITICAL: 0)` and passes a fixable-CRITICAL gate, against `Total: 21
> (CRITICAL: 21)` on `2.1.3` as the control.
>
> ## What is still worth something here
>
> - **[chuckcharlie/cups-avahi-airprint#61](https://github.com/chuckcharlie/cups-avahi-airprint/pull/61)
>   is open and still needed.** The entrypoint runs under `set -x`, so the credential block traces
>   `CUPSPASSWORD` in clear text on every start. This is **still true in `2.2.0`** — verified by
>   running the image with a random sentinel as the password and finding it twice in the log, with
>   two positive controls beside it. That PR wraps the block in `set +x` / `set -x`. This
>   repository is archived rather than deleted precisely so that PR's branch survives.
> - **The multi-stage `Dockerfile` on `master`** builds the same functionality on `alpine:3.24`
>   with no `edge` repositories and no build toolchain in the final image: **230 MB against
>   upstream's 695 MB**, 110 packages against 209, and zero findings at CRITICAL or HIGH. If
>   anyone wants a smaller or supported-base image, start there rather than from scratch.
> - **`.github/workflows/build-push.yml`** was offered upstream as
>   [#62](https://github.com/chuckcharlie/cups-avahi-airprint/pull/62) and declined. It still works
>   if you want to build this yourself.
>
> **Use upstream's image**: `docker.io/chuckcharlie/cups-avahi-airprint:2.2.0`. The `ghcr.io`
> images this repository published are frozen at 2026-11-18 and are not rebuilt or rescanned.
>
> Everything below is the original text, left as written.

# About this fork

This is a fork of [chuckcharlie/cups-avahi-airprint](https://github.com/chuckcharlie/cups-avahi-airprint),
itself a fork of [quadportnick/docker-cups-airprint](https://github.com/quadportnick/docker-cups-airprint).
It exists for one reason: **upstream's source is maintained, but its published image is not.**

## Why it exists

Upstream builds in AWS CodeBuild (`buildspec.yml`) and publishes to Docker Hub. That pipeline has
stopped producing images:

| | |
|---|---|
| newest tag on Docker Hub | `2.1.3`, pushed 2026-06-17 |
| `version.txt` on upstream `master` | `2.2.0` |
| commits to upstream `master` since that image | many, including CUPS config parsing fixes |

So the only image anyone can pull is a frozen snapshot of Alpine edge as it stood in June. The
Dockerfile pins `FROM alpine:3.20` but appends the three Alpine `edge` repositories on top, so what
lands in the image is whatever edge held *on build day*. An image nobody rebuilds therefore rots
without a single commit landing: by 2026-11-18 the `2.1.3` image carried 152 findings at HIGH or
CRITICAL, **all 152 of them with a fix already published by Alpine**, 21 of them CRITICAL.

Nothing upstream did is wrong here. The packages are fixed; the fix just never got built.

## What this fork changes

Five things. The first three were deliberately minimal, to get a fresh image published without
touching how it is built. The last two are the restructure that those three made possible.

1. **`.github/workflows/build-push.yml`** — builds on GitHub's runners and publishes to
   `ghcr.io`, weekly as well as on every push, with a smoke test and a Trivy gate that both run
   *before* anything is pushed. The workflow file carries its own reasoning in comments.

2. **`hplip` is no longer installed.** It is HP's driver stack and it brought ten CRITICAL CVEs
   (`CVE-2026-91097` … `CVE-2026-91106`) with it, each firing twice because `hplip` and
   `hplip-libs` both carry it. Nothing in the image depends on it, no script under `root/`
   references it, and dropping it removes the `hp` CUPS backend while leaving fourteen others.
   Re-add it if you front an HP printer; the Dockerfile says so at the point of removal.
   The images this fork was built for drive a Brother laser through `brlaser`, which the
   Dockerfile compiles from source and which the CI smoke test asserts is present.

3. **`run_cups.sh` no longer traces the admin password.** The script runs under `set -x`, which
   traces each command with its arguments already expanded, so the credential block printed
   `CUPSPASSWORD` in clear text on every start — twice, once as `+ '[' -z <password> ]` and once
   as `+ echo <user>:<password>`. On the host this fork was made for that had left 20 copies of
   the password in the journal, the oldest a month old. Tracing is now off for that block and
   restored immediately after.

   CI asserts it stays off, with two positive controls alongside the absence check: a test that
   only greps for a missing secret passes just as happily when the log is empty or the block was
   deleted, so the job also requires evidence that the block ran and that tracing came back.

   The same change quotes the expansions and uses `printf` instead of `echo`. Unquoted, a password
   containing whitespace or a glob character was mangled before it reached `chpasswd`. That is a
   deviation from upstream behaviour and an intentional one.

4. **`FROM alpine:3.24`, with the `edge` repositories removed.** Upstream pins `alpine:3.20` and
   then appends all three Alpine `edge` repositories on top. 3.20 is past end of life, which Trivy
   says out loud on every scan of it:

       WARN  This OS version is no longer supported by the distribution  version="3.20.10"
       WARN  The vulnerability detection may be insufficient because security updates are not provided

   A clean report against an unsupported branch is not reassurance, it is missing data.

   The `edge` repositories were almost certainly there to reach a newer `hplip` than 3.20 carried:
   3.20 has `3.23.12-r2` and upstream wanted `3.26.x`. With hplip gone, every remaining package is
   in 3.24's own `main` and `community` — checked one by one before the change — so the image stops
   mixing a stable base with a rolling one. Trivy now matches it against `repository="3.24"` rather
   than `repository="edge"`.

5. **Two stages.** The toolchain that compiles brlaser and gutenprint stays in the builder and
   never reaches the published image.

   This is a restructure rather than a cleanup because deleting `build-base` in a later layer would
   not shrink anything: a deletion in a new layer only adds a whiteout over files that remain
   below. An earlier attempt at a derived image (`FROM 2.1.3` plus `apk upgrade`) proved the point
   by growing from 730 MB to **1.29 GB**. The only way the toolchain leaves is never to be in the
   final stage.

   Gutenprint's build artifacts are pruned in the builder for the same reason, before the `COPY`.
   The largest single item is 21 MB of translated option names, which nothing reads on a headless
   relay.

### What that comes to

| | upstream `2.1.3` | this fork |
|---|---|---|
| size | 730 MB | **230 MB** |
| packages | 209 | **110** |
| Alpine | 3.20.10, past EOL | **3.24.4** |
| findings at CRITICAL or HIGH | 152 | **0** |
| Trivy EOL warning | yes | **no** |

The last row matters as much as the one above it. The zero means something now, rather than being
an artifact of a branch Alpine no longer publishes data for.

### The assertions in the Dockerfile

The final stage ends with two `RUN` blocks that assert outcomes rather than trusting commands.
They are the part of this fork most worth reading before changing anything.

Upstream applies eleven `sed -i` edits to `cupsd.conf` and `avahi-daemon.conf`. A `sed` whose
pattern does not match exits 0 and changes nothing, so a base-image update can silently drop one
and the build still succeeds. The cost is not cosmetic: lose the first edit and cupsd listens on
localhost only, and AirPrint stops working with nothing in any log to say why. One of the eleven is
**already** a no-op — `Browsing Off` matches neither 3.24 nor 3.20, and both published images carry
`Browsing Yes` — so that assertion accepts `Yes` or `On` instead of demanding the substitution.

The second block checks the image can drive a printer: both source-compiled filters exist, the
gutenprint XML data is present, `cups-genppdupdate` kept its perl shebang, and four binaries report
no unresolved libraries.

That last check asks only whether anything is **unresolved**. A first version demanded that the
filter resolve `libgutenprint`, and failed the build — wrongly. Nothing links `libgutenprint.so`
dynamically, in this image or in the one upstream publishes; both have it compiled in statically.
The Dockerfile says so at that line, so the wrong assertion does not come back. The check also
fails if `ldd` lists no libraries at all, because an absence test that looks at nothing passes
every time.

## Tags

| tag | what it is |
|---|---|
| `2.2.0` | upstream's `version.txt` |
| `2.2.0-<YYYYMMDD>` | **pin this.** Same bytes until you choose to move |
| `latest` | convenience |
| `sha-<short>` | traceable to a commit |

Pin the dated tag rather than `latest`. A pinned image will eventually go red in your own
vulnerability scan as it ages, and that is the signal to bump it — which is better than an
unattended auto-update moving a printing service while someone is printing.

## Keeping up with upstream

```bash
git remote add upstream https://github.com/chuckcharlie/cups-avahi-airprint.git
git fetch upstream
git merge upstream/master
```

Two conflicts are expected and intended: the `apk add` list, where upstream still installs
`hplip`, and the credential block in `root/root/run_cups.sh`. Resolve both by keeping the fork's
version. CI asserts `hplip` is absent and that the password does not reach the log, so a merge
that undoes either one fails rather than quietly shipping it.

## Licence

Upstream is GPL-3.0 and so is this fork; `LICENSE` is unchanged. Publishing a built image from
modified sources is exactly what the licence contemplates, and the modified sources are this
public repository.

## The better fix

The ideal outcome is that this fork becomes unnecessary: upstream has 224 stars, no GitHub Actions
workflow at all, and a build pipeline that has quietly stopped publishing. The workflow here is
offered upstream rather than kept private, and if it lands, pulling upstream's own image becomes
the right answer again.
