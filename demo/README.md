# A sovereign CI/CD platform on Tekton — demo

One kind cluster, one domain, one signing key. Every team releases through
Pipelines-as-Code with a single file in its repository; the platform's golden
path is an OCI bundle signed by Tekton Chains; admission decides which bundle may
run and as whom; and the whole chain can be verified with cosign from outside the
cluster.

Nothing signs from a workstation. The private key is generated into the secret
`tekton-chains/signing-secrets` and is read only by the Chains controller.

```
        push to acme/app                      Tekton control plane
              │                                       │
   .tekton/release.yaml ──► Pipelines-as-Code ──► PipelineRun
   (the whole CI a team owns)                     │
                                                  ├─ clone
                                                  ├─ build   (rootless buildkit) ──► zot
                                                  ├─ scan    (Trivy gate: records SCAN_GATE, fails the run)
                                                  ├─ sbom    (CycloneDX, attached)
                                                  └─ promote (declares the artifact to Chains)
                                                                 │
                                                        Chains signs + attests
                                                                 │
                        admission (ValidatingAdmissionPolicy) ────┘
                        which bundle · which user
```

## Requirements

`docker`, `kind`, `kubectl`, `helm`, `cosign`, `python3`, `jq`, `openssl`, `git`.
Versions of everything the cluster installs are pinned in `versions.env`.
`kind` must be able to publish ports 80 and 443 on the host.

## Quickstart

```sh
make up      # from nothing: cluster, ingress, registry, Tekton, forge, platform
make demo    # the four examples, in order
make down    # delete the cluster
```

`make help` lists every target. `make status` prints the endpoints and anything
that is not running.

| step | measured |
|---|---|
| `make up` | 4m19s from an empty host, with the kind node image already cached; add a few minutes the first time kind has to download it |
| `make demo` | 2m51s, of which two minutes are builds |
| `make example-1` | ~70s (build, Trivy DB, SBOM) |
| `make example-1b` | ~60s |
| `make example-2` | ~10s |
| `make example-3` | 7s |

The four examples are also runnable one at a time, which is how the talk uses
them: `make example-1`, `make example-1b`, `make example-2`, `make example-3`.

### The sequence on stage

```sh
make status       # endpoints and the digest the platform approved
make example-1    # the happy path: build, gate, SBOM, signature        (~70s)
make trust        # cosign from outside: signed bundle ✔, unsigned copy ✘ (~2s)
make example-2    # refused at admission: no run is created             (~10s)
make example-3    # refused at the pod: the run exists and fails        (~7s)
make example-1b   # the gate fails and nothing is signed                (~60s)
```

`make demo` runs all four in that order. If the laptop was closed overnight, run
`make recover` first; between takes, `make clean`.

## What the platform installs

| namespace | component | why |
|---|---|---|
| `haproxy-ingress` | HAProxy Kubernetes Ingress Controller | one hostname for host and pods |
| `zot` | zot (OCI-native) | images, signed pipeline bundles, attestations |
| `tekton-pipelines` | Pipelines, Dashboard, remote resolvers | the delivery engine |
| `tekton-chains` | Chains | SLSA provenance and signatures, key held here |
| `pipelines-as-code` | Pipelines-as-Code | the teams' entry point: a push starts a run |
| `forgejo` | Forgejo | the forge the teams push to |
| `team-a` | — | the team: namespace, ServiceAccounts, RBAC, one `Repository` CR |
| `platform` | — | the publisher identity and the bundle publication |

One hostname works from both sides without editing `/etc/hosts`: `sslip.io`
encodes `127.0.0.1` in the name for the host, and CoreDNS is given the same names
for the pods (`scripts/dns.sh`).

## The four examples

Each example is one push to `acme/app`. What the team owns is the file in
`team/app/.tekton/`, and the four of them are the four attacks and the happy
path. `scripts/example.sh` pushes the branch, follows the run and then *checks*
that the outcome is what it claims to be.

### Example 1 — the signed bundle

```sh
make example-1
```

`team/app/.tekton/release.yaml` references the bundle the platform published
(`platform/pipelines/go-service:1.0.0`), and Pipelines-as-Code turns it into a
PipelineRun on every push to `main`.

You should see five tasks and a run that succeeds:

```
release-hrv8w   True   Succeeded
    Succeeded=True Tasks Completed: 5 (Failed: 0, Cancelled 0), Skipped: 0
```

then, from the `promote` step:

```
declared to Tekton Chains: zot.…/team/app@sha256:15c870fa…
```

and then the two checks the script runs itself:

```
✔ image signature verified (Chains)
✔ SLSA provenance verified (Chains)
```

**What to say:** the bundle that ran is the one the platform signed, and the
image it produced is signed and carries SLSA provenance — both with a key that no
step of this pipeline could read.

### Example 1b — the gate fails, so nothing is signed

```sh
make example-1b
```

The same signed bundle, on the `scan-fail` branch, with the vulnerable
`Dockerfile` from `team/app/vulnerable/` (an application built in 2021). The
Trivy gate fails the `scan` task:

```
release-scan-fail-rfzqd   False   Failed
    Succeeded=False Tasks Completed: 3 (Failed: 1, Cancelled 0), Skipped: 2
    release-scan-fail-rfzqd-scan   False   Failed
    Total: 15 (HIGH: 14, CRITICAL: 1)      # in the base image
    Total: 58 (HIGH: 54, CRITICAL: 4)      # in the Go standard library
```

`sbom` and `promote` are skipped. buildkit *did* push the image, and it is
sitting in the registry — but nothing signed it. The `scan` task also records its
verdict on the run, and it does so in both branches: a result written before a
step fails is still published by Tekton, so a red gate leaves a trace.

```
▸ the image buildkit pushed, unsigned: zot.…/team/app@sha256:c332a999…
✔ cosign verify refuses it — the control plane signed nothing
✔ il verdetto è registrato sulla run: SCAN_GATE=failed — è la condizione di promote
▸ what Tekton Chains did with the failed run:
    No image subject to attest for tekton.dev/v1/PipelineRun/team-a/release-scan-fail-rfzqd.
    Skipping upload to registry
```

**What to say:** *this is the reason the verdict inside the pipeline matters.*
Tekton Chains signs a run when it *completes* — failed runs included. A pipeline
that puts `IMAGE_URL`/`IMAGE_DIGEST` on its build task therefore gets a signature
even when the scan says the image is unusable. Here only the last task, `promote`,
carries those names, **and it is conditioned on `SCAN_GATE=passed`** (the `when:`
in the Pipeline): no positive verdict, no artifact declared, nothing for Chains to
sign — whatever the exit status of the run, and wherever the task sits in the DAG.
The evidence is the "No image subject to attest" line above.

### Example 2 — a bundle nobody signed

```sh
make example-2
```

The bundle reference is a plain OCI artifact, and pushing an OCI artifact needs
nothing but registry access — that is the hole a registry alone cannot close.
`make unsigned` (part of `make platform`) pushes a copy of the golden path with
one comment added: different bytes, different digest, no signature. It goes into
the platform's *own* repository on purpose, so the refusal is about the digest
and not about where it lives.

This time no PipelineRun is created at all:

```
▸ no PipelineRun was created: the request was rejected at admission
  Tekton Controller has reported this error: pipelineruns.tekton.dev "release-unsigned-ck2bm"
  is forbidden: ValidatingAdmissionPolicy 'tekton-bundle-entitlement' with binding
  'tekton-bundle-entitlement-deny' denied request: bundle non approvato: la piattaforma
  ha approvato solo zot.…/platform/pipelines/go-service@sha256:77cb7849… (firmato da Tekton Chains)
```

Pipelines-as-Code reports that refusal on the commit, so the team sees why.

**What to say:** the workload never exists. There is no shell, no container, no
privilege to escalate — entitlement decided at admission, not inside the pipeline.

### Example 3 — the same signed pipeline, started as root

```sh
make example-3
```

The bundle is the approved one; the only difference is in the PipelineRun:

```yaml
  taskRunTemplate:
    podTemplate:
      securityContext:
        runAsUser: 0
```

The run is admitted, so it exists and *fails*:

```
release-as-root-ktslm   False   Failed
    Succeeded=False Tasks Completed: 1 (Failed: 1, Cancelled 0), Skipped: 4
    release-as-root-ktslm-clone   False   PodCreationFailed
▸ why the run failed:
    failed to create task run pod "release-as-root-ktslm-clone": pods "release-as-root-ktslm-clone-pod"
    is forbidden: ValidatingAdmissionPolicy 'tekton-non-root' with binding 'tekton-non-root-deny'
    denied request: pod non ammesso: runAsUser 0 (root) è vietato nelle pipeline dei team
```

**What to say:** the pipeline is the platform's — the team only chose the pod
template. Enforcing on the *pod* rather than on the PipelineRun is deliberate:
the refusal shows up as a failed run in the Dashboard and on the commit, which is
what an operator wants to see. A rejected object would leave no trace in Tekton.

## How the signing works

One key pair, in `tekton-chains/signing-secrets`, read by the Chains controller
and by nothing else. It signs two different things:

| artifact | produced by | stored as |
|---|---|---|
| the pipeline bundle | the `publish` PipelineRun in the `platform` namespace | a cosign signature on the OCI artifact in zot |
| every team's image | the team's own PipelineRun | a cosign signature plus SLSA v1.0 provenance in zot |

Chains decides what to sign by reading the run's **results**: the names
`IMAGE_URL` and `IMAGE_DIGEST` are type hints — whatever those results point at
is treated as an artifact to sign and attest. That is the whole mechanism, and it
is why example 1b can control it by *where* those results are produced.

`make publish` then does what a release gate would do: wait for Chains, run
`cosign verify` with the public key, and record the digest only if the signature
verifies. `make policies` pins exactly that digest at admission.

```sh
make trust   # approved bundle ✔ · unsigned copy ✘ · last built image + provenance ✔
```

**The split, stated plainly:** admission cannot call cosign, so it does not check
the signature; it checks a digest that the platform *verified* out-of-band. That
is a deliberate trade-off (see below).

## Operations

| | |
|---|---|
| `make status` | endpoints, the approved digest, anything not ready |
| `make verify` | the same hostname resolves and answers from the host and from a pod |
| `make clean` | delete the runs and PVCs the demo accumulated |
| `make record` | record the four examples as GIFs for the deck (`asciinema` + `agg`) |
| `make recover` | bring the cluster back after a Docker restart, and rotate the Tekton webhook certificate |
| `make down` | delete the cluster |
| `make policies-warn` | roll the entitlement rule out in warning mode: the run is created and the client is told |
| `make trusted` | extra: Trusted Resources — the platform signs a *Task* and the control plane refuses a tampered copy |

Two failures look like "the demo is broken" and are not:

* **The node is not running.** Docker Desktop restarting leaves the kind
  container exited, and starting it again can fail with *"have an old IPv4
  address but no current IPv4 address"*. `make recover` re-attaches the container
  to the `kind` docker network, starts it and waits for the platform.
* **Every `kubectl apply` of a Tekton object fails with `x509: certificate has
  expired`.** The Tekton webhook certificate is valid for 7 days and its rotation
  controller does not fire while the node is down. `make recover` restarts the
  webhook, which regenerates it. **A cluster left alone for a week needs this
  before the demo.**

## Recordings

Two kinds, for two jobs: the **developer experience** in the browser is what the
slides show, and the **terminal** recordings are the evidence — the runbook, and
the place to find a message verbatim.

### The developer experience (what the slides show)

Four recordings of the real flow: the push in Forgejo, then the run in the Tekton
Dashboard. Each one is the whole browser window, **uncropped**, so the slide shows
exactly what the developer sees.

| file | what it shows |
|---|---|
| `record/dx-1.mp4` | push on `main`: the commit appears, the run goes `Running` → `Succeeded`, and back on the forge the badge is green |
| `record/dx-1b.mp4` | push on `scan-fail`: the Trivy gate fails, and the `scan` task is opened to show its logs |
| `record/dx-2.mp4` | push on `unsigned`: the commit gets a red ✗ and **no run appears** in the list |
| `record/dx-3.mp4` | push on `as-root`: the run is created and fails, `clone` is `PodCreationFailed` |

The `.png` beside each one is the poster: a `<video>` renders its poster in a
print export, so the PDF keeps a frame that says something.

### The terminal (the evidence)

`make record` runs all four examples for real under
[asciinema](https://asciinema.org) and converts each session with
[agg](https://docs.asciinema.org/manual/agg/):

```sh
brew install asciinema agg     # once
make record                    # ~3 minutes: it runs the examples against the cluster
make record S=3                # or just one: S=1, S=1b, S=2, S=3
```

Per example, into `demo/record/`: `example-N.cast` (replay with
`asciinema play demo/record/example-1.cast`), `example-N.gif` (120x20, 5x speed)
and `example-N.png` (the settled screen).

These are **not in the deck**: they are the runbook, and where a message can be
quoted exactly — `No image subject to attest … Skipping upload to registry`, the
ValidatingAdmissionPolicy denial, the `PodCreationFailed` text. Geometry is fixed
at 120x20 so the four share one shape.

### How the browser recordings are made

Manual, and the only step `make record` does not cover. Each recording follows the
**developer's** flow, not a script's — the push itself is on camera:

1. sign in to Forgejo **as the developer** — `dev`, password in `versions.env` —
   once, before recording. The session lives in the browser profile, so the videos
   never show a login form, and the commits are attributed to a person instead of
   to the forge admin.
2. open `/_edit/<branch>/main.go` for the branch the example uses, type a line in
   the **web editor**, and press *Commit changes* → that push is what triggers
   Pipelines-as-Code, and it is the first thing each video shows
3. switch to the Forgejo commits page: the commit carries Pipelines-as-Code's
   status (green ✓, or the red ✗ of a refused run)
4. switch to the Dashboard: the run appears (or does not, for the refused bundle),
   and the failing task is opened for its logs — or its **Status** tab, where the
   admission denial is spelled out

Two things make this fiddly, and both cost time:

- the editor is **CodeMirror**, so the text must arrive as real keystrokes
  (`page.keyboard.type`), not as a value assignment; and the commit summary field
  has to be filled *before* the footer button, which submits the form in one click
- **hold each screen for a few seconds**: the recorder emits only changed frames, so
  a page that changes once is a single frame, and without the dwell the `✗` flashes
  past

Mechanically:

1. a Chrome with a debugging port, on its own profile. The window is **2560x1527**,
   which gives a **2560x1440 viewport** — exactly 16:9 at 2K, so the video fills a
   2K display with no letterboxing and no cropping:
   ```sh
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless=new --remote-debugging-port=9222 --user-data-dir=/tmp/ui-chrome \
     --window-size=2560,1527 about:blank
   ```
2. drive it over CDP — `Page.startScreencast` for the video, navigation and clicks
   for the flow. Any CDP client will do; the recording has to come from the browser,
   not from the screen.
3. encode **without scaling** (the crop was removed on purpose: the whole window,
   so nothing of the page is cut), and take a poster:
   ```sh
   ffmpeg -i raw.webm -vf "setpts=PTS/3.5" -fps_mode cfr -r 25 \
     -c:v libx264 -preset medium -crf 26 -pix_fmt yuv420p -movflags +faststart dx-1.mp4
   ffmpeg -i raw.webm -ss 95 -frames:v 1 dx-1.png
   ```

The run happens for real, so **this is the heaviest step for the disk**: four runs
leave four 1 Gi PVCs and four new image digests in zot. Run `make clean` and prune
the node afterwards: the cluster fills the Docker VM.

Three traps, all hit while doing this. A headless screenshot of the Dashboard's
SPA returns a **loading skeleton** unless the client waits for the data (Chrome's
`--screenshot` flag alone does not). The run names in the captures are generated,
so nothing in the deck may depend on them — and a selector that matches only
`release-<5 chars>` silently matches nothing for `release-scan-fail-*`. And
**Chrome does not autoplay a muted `<video>` on a page opened from `file://`** —
not at load, not when the slide scrolls into view; measured in both headless and
headed Chrome. That is why the last example slide carries a few lines of script:
they call `play()` on the first keypress or click and whenever a video becomes
visible. Without it the deck would sit quietly on the poster.

## Trade-offs and limits, deliberately

* **No transparency log.** `transparency.enabled: false`: nothing leaves the
  cluster, which is the point of the talk. Rekor is one config line away and is
  what a real deployment should turn on.
* **Admission pins a digest, it does not verify a signature.** A
  ValidatingAdmissionPolicy cannot run cosign. Verifying the signature *at
  admission* needs an admission webhook that can (Kyverno `verifyImages`,
  sigstore policy-controller, or Tekton's own Trusted Resources) — see
  `make trusted` for what that looks like here.
* **The registry is spoken to over plain HTTP, with `--insecure` in the build and
  the scan.** The bundle resolver has no "insecure" option, so the demo issues a
  certificate from its own CA and teaches the Tekton controllers to trust it
  (`scripts/tls.sh`); the remaining `--insecure` flags are a shortcut that a real
  setup replaces by mounting the same CA into the pods.
* **A namespace-level `restricted` Pod Security Standard is stricter than the
  non-root policy**, but it also forbids the `Unconfined` seccomp profile the
  rootless buildkit worker needs. The trade-off is documented in
  `platform/policies/vap-nonroot.yaml`.
* **The Dashboard is writable and has no authentication.** It is a local demo
  cluster; the write role is granted per namespace (`dashboard-operator`), never
  cluster-wide.
* **The signing key is a static key in a Secret**, not a KMS/HSM.

## Where everything lives

```
Makefile                     the whole interface: make up / demo / down
versions.env                 every pinned version and name
kind/cluster.yaml            one node, ports 80/443 published on the host
values/                      helm values for the ingress controller, zot, forgejo

platform/pipelines/go-service.yaml   the golden path (published as a signed bundle)
platform/publish/                    the platform's own publisher task + run
platform/policies/vap-entitlement.yaml   which bundle may run
platform/policies/vap-nonroot.yaml       as whom it may run
platform/tasks/hello.yaml            the Task used by the extra `make trusted`

team/app/.tekton/                    the four examples, one file each
team/app/vulnerable/Dockerfile       the app that must fail the gate

scripts/install-tekton.sh   Pipelines, Chains, Dashboard, Pipelines-as-Code
scripts/tls.sh              our CA + the registry certificate
scripts/dns.sh              the same FQDNs inside the cluster
scripts/chains.sh           the key pair and the Chains configuration
scripts/team.sh             team namespace, ServiceAccounts, RBAC
scripts/forgejo.sh          forge org/repo/accounts/secrets/webhook + enrolment
scripts/publish.sh          publish the golden path, verify the signature, approve it
scripts/unsigned.sh         the bundle nobody signed
scripts/policies.sh         render and apply both admission policies
scripts/example.sh           push one example and check its outcome
scripts/record.sh            record the examples under asciinema, for the deck
scripts/trust.sh            cosign verification, from outside
scripts/clean.sh            delete runs and volumes
scripts/recover.sh          bring a dead cluster back
scripts/push-bundle.py      build the OCI bundle by hand (zot rejects tkn's format)
keys/                       the public keys and the demo CA
record/                     dx-*.mp4 = the browser recordings the slides show
                            example-*.{cast,gif,png} = the terminal evidence
```
