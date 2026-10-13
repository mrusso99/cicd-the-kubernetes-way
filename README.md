# A sovereign CI/CD platform on Tekton — slides and demo

The talk, and the thing the talk is about: **47 slides** plus a demo that runs the
whole story on a laptop. One kind cluster, one domain, one signing key. Every team
releases through Pipelines-as-Code with a single file in its repository; the
platform's golden path is an OCI bundle signed by Tekton Chains; admission decides
which bundle may run and as whom; and the whole chain can be verified with cosign
from outside the cluster.

| path | what it is |
|---|---|
| `slides.pdf` | the deck, 47 slides, as presented. The four example videos are frozen as posters |
| `slides.pptx` | the same deck, editable (Keynote, PowerPoint, Google Slides), with the four `dx-*.mp4` **embedded** — they play inside the deck |
| `demo/` | the demo the deck is built on: kind cluster, platform manifests, scripts, Makefile |
| `demo/README.md` | the full walkthrough: what the platform installs, all four examples in detail, how the signing works, trade-offs |

## The slides

`slides.pptx` is the one to present from: the example slides carry the real
recordings, embedded, and play on click. `slides.pdf` is the same deck for reading,
printing or sharing, with a poster frame where each video sits.

The videos are the developer's own flow — the push in Forgejo, then the run in the
Tekton Dashboard — recorded uncropped, so a slide shows exactly what the developer
sees. Their source files stay in `demo/record/` (`dx-*.mp4` plus a `.png` poster
each), alongside the terminal recordings used as the runbook.

## The demo

Requirements: `docker`, `kind`, `kubectl`, `helm`, `cosign`, `python3`, `jq`,
`openssl`, `git`. Ports 80 and 443 must be free. Every version and every name the
cluster installs is pinned in `demo/versions.env`.

```sh
cd demo
make help        # every target
make up          # from nothing: cluster, ingress, registry, Tekton, forge, platform   (~4m20s)
make demo        # the four examples, in order                                        (~2m50s)
make down        # delete the cluster
```

Everything answers on one hostname derived from `DEMO_DOMAIN` in
`demo/versions.env` — `forgejo.`, `dashboard.` and `zot.` under a `sslip.io` name
that already encodes `127.0.0.1`, so no `/etc/hosts` edit and no local DNS. The
same names resolve inside the cluster (`demo/scripts/dns.sh`).

```sh
make status      # endpoints and the digest the platform approved
```

### The sequence on stage

```sh
make status       # endpoints and the approved digest
make example-1    # the happy path: build, gate, SBOM, signature        (~70s)
make trust        # cosign from outside: signed bundle ✔, unsigned copy ✘ (~2s)
make example-2    # refused at admission: no run is created             (~10s)
make example-3    # refused at the pod: the run exists and fails        (~7s)
make example-1b   # the gate fails and nothing is signed                (~60s)
```

`make demo` runs all four examples in that order. A cluster left alone overnight
needs `make recover` first (Tekton's webhook certificate expires in 7 days);
`make clean` between takes removes the runs and volumes they leave behind.

`demo/README.md` has the whole thing: the platform's namespaces and components, what
each example proves and what to see in its output, the signing mechanism, and the
trade-offs that were chosen on purpose.

## Layout

```
slides.pdf / slides.pptx      the deck
demo/Makefile                 the whole interface: make up | demo | down
demo/versions.env             every pinned version, name and demo account
demo/kind/cluster.yaml        one node, ports 80/443 published on the host
demo/values/                  helm values: ingress controller, zot, forgejo
demo/platform/pipelines/      the golden path, published as a signed bundle
demo/platform/publish/        the platform's own publisher task and run
demo/platform/policies/       the two admission policies (which bundle, as whom)
demo/team/app/.tekton/        the four examples, one file each
demo/scripts/                 install, tls, dns, chains, forgejo, publish, example, record…
demo/record/                  the recorded runs the deck shows (mp4 + posters) and the terminal casts
demo/keys/                    generated at run time by scripts/chains.sh and scripts/tls.sh (git-ignored)
```
