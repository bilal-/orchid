# Research grounding

Orchid's design pillars each cite literature that genuinely supports
them — the rule is **relevance, not volume**: padding with tangential
papers reads as spam and inverts credibility (`docs/specs/roadmap.md`'s own
framing for this page). Every citation below was verified live against its
actual published venue during this task (title, authors, venue, year, and a
working link fetched via web search/fetch, not carried over from
design-time memory) — nothing here is guessed, and nothing that couldn't be
verified is listed.

## Pillar map

### Multi-agent division of labor for software development

Orchid's core shape — separate roles (implementer, reviewer, arbiter,
plan critic) held by independently-invoked engines — is not a novel claim;
it follows a line of work showing that decomposing a coding task across
role-specialized LLM agents outperforms a single monolithic session:

- Hong, Sirui, et al. **"MetaGPT: Meta Programming for a Multi-Agent
  Collaborative Framework."** arXiv:2308.00352 (2023).
  <https://arxiv.org/abs/2308.00352>
- Qian, Chen, et al. **"ChatDev: Communicative Agents for Software
  Development."** *Proceedings of ACL 2024*, pp. 15174–15186.
  arXiv:2307.07924. <https://arxiv.org/abs/2307.07924>
- Wu, Qingyun, et al. **"AutoGen: Enabling Next-Gen LLM Applications via
  Multi-Agent Conversation."** arXiv:2308.08155 (2023).
  <https://arxiv.org/abs/2308.08155>
- Li, Guohao, et al. **"CAMEL: Communicative Agents for 'Mind' Exploration
  of Large Language Model Society."** arXiv:2303.17760 (2023).
  <https://arxiv.org/abs/2303.17760>

### Nobody signs off on their own work / engine independence

Orchid's review-independence rules (`docs/specs/kernel.md`'s Independence
section: session independence vs. engine independence, routed by risk
tier) rest on two findings: LLM judges are a workable evaluation signal in
general, but they are measurably biased toward their own outputs — which is
precisely why orchid never lets the implementing engine also review its own
candidate:

- Zheng, Lianmin, et al. **"Judging LLM-as-a-Judge with MT-Bench and
  Chatbot Arena."** *Advances in Neural Information Processing Systems 36*
  (NeurIPS 2023). arXiv:2306.05685. <https://arxiv.org/abs/2306.05685>
- Panickssery, Arjun, Samuel R. Bowman, and Shi Feng. **"LLM Evaluators
  Recognize and Favor Their Own Generations."** arXiv:2404.13076 (2024).
  <https://arxiv.org/abs/2404.13076>

### Reviewer diversity & arbitration on disagreement

Dual review for `medium`/`high` risk tasks, and inline orchestrator
arbitration when reviewers disagree (`docs/specs/kernel.md`'s Arbitration
section), follow the same logic these papers establish empirically —
multiple independent model perspectives, aggregated or debated, resolve
disagreement and improve reliability over any single one:

- Du, Yilun, Shuang Li, Antonio Torralba, Joshua B. Tenenbaum, and Igor
  Mordatch. **"Improving Factuality and Reasoning in Language Models
  through Multiagent Debate."** *ICML 2024*. arXiv:2305.14325 (2023).
  <https://arxiv.org/abs/2305.14325>
- Li, Junyou, Qin Zhang, Yangbin Yu, Qiang Fu, and Deheng Ye. **"More
  Agents Is All You Need."** arXiv:2402.05120 (2024).
  <https://arxiv.org/abs/2402.05120>
- Wang, Junlin, Jue Wang, Ben Athiwaratkun, Ce Zhang, and James Zou.
  **"Mixture-of-Agents Enhances Large Language Model Capabilities."**
  *ICLR 2025*. arXiv:2406.04692 (2024). <https://arxiv.org/abs/2406.04692>

### Rework, journal, lessons (memory design)

Orchid's rework loop (task-scoped, re-attempted against reviewer findings),
the append-only decision journal, and cross-run lessons
(`docs/specs/kernel.md`, Memory & resumption) draw on the same lineage of
work on giving language agents durable, structured memory across attempts
rather than relying on ever-larger context windows alone:

- Shinn, Noah, Federico Cassano, Edward Berman, Ashwin Gopinath, Karthik
  Narasimhan, and Shunyu Yao. **"Reflexion: Language Agents with Verbal
  Reinforcement Learning."** *NeurIPS 2023*. arXiv:2303.11366 (2023).
  <https://arxiv.org/abs/2303.11366>
- Madaan, Aman, et al. **"Self-Refine: Iterative Refinement with
  Self-Feedback."** *NeurIPS 2023*. arXiv:2303.17651 (2023).
  <https://arxiv.org/abs/2303.17651>
- Wang, Guanzhi, et al. **"Voyager: An Open-Ended Embodied Agent with
  Large Language Models."** *Transactions on Machine Learning Research*
  (2024). arXiv:2305.16291 (2023). <https://arxiv.org/abs/2305.16291>
- Park, Joon Sung, Joseph C. O'Brien, Carrie J. Cai, Meredith Ringel
  Morris, Percy Liang, and Michael S. Bernstein. **"Generative Agents:
  Interactive Simulacra of Human Behavior."** *Proceedings of the 36th
  Annual ACM Symposium on User Interface Software and Technology (UIST
  2023)*. arXiv:2304.03442. <https://arxiv.org/abs/2304.03442>
- Packer, Charles, Sarah Wooders, Kevin Lin, Vivian Fang, Shishir G.
  Patil, Ion Stoica, and Joseph E. Gonzalez. **"MemGPT: Towards LLMs as
  Operating Systems."** arXiv:2310.08560 (2023).
  <https://arxiv.org/abs/2310.08560>

### Deterministic verification over model claims; agentic SE evaluation

`orchid verify` is the single, deterministic source of "tests pass" —
never an engine's own narration (`docs/specs/kernel.md`'s kernel
guarantees: "tests pass only via `orchid verify`"). This follows the
same standard agentic-coding benchmarks hold real systems to: an agent's
own claim of success is not evidence, only a verifiable test/patch outcome
is:

- Jimenez, Carlos E., et al. **"SWE-bench: Can Language Models Resolve
  Real-World GitHub Issues?"** *ICLR 2024*. arXiv:2310.06770 (2023).
  <https://arxiv.org/abs/2310.06770>
- Yang, John, Carlos E. Jimenez, Alexander Wettig, Kilian Lieret, Shunyu
  Yao, Karthik Narasimhan, and Ofir Press. **"SWE-agent: Agent-Computer
  Interfaces Enable Automated Software Engineering."** *NeurIPS 2024*.
  arXiv:2405.15793 (2024). <https://arxiv.org/abs/2405.15793>
- Osmani, Addy, Shubham Saboo, and Sokratis Kartakis. **"The New SDLC With
  Vibe Coding."** Google whitepaper (Kaggle, June 2026).
  <https://www.kaggle.com/whitepaper-the-new-SDLC-with-vibe-coding> — the
  source of orchid's own **trajectory evaluation** framing: judging *how*
  an agent reached a result (tool calls, reasoning path), not only the
  result itself, which is exactly what `diagnostics.trajectory_log` in
  orchid's result envelope (`docs/specs/plugins.md`) exists to preserve
  even though orchid's own pass/fail gate stays outcome-based (`orchid
  verify`).

### Harness > model; factory model; model routing

Orchid's whole premise — a deterministic, engine-agnostic kernel plus
interchangeable vendor CLIs bound to roles by capability, never by
identity — matches this framing directly: the harness (verification,
role separation, memory, guardrails) determines reliability far more than
which specific model sits behind any one role:

- Osmani, Addy, Shubham Saboo, and Sokratis Kartakis. **"The New SDLC With
  Vibe Coding."** Google whitepaper (Kaggle, June 2026).
  <https://www.kaggle.com/whitepaper-the-new-SDLC-with-vibe-coding> — the
  paper's central equation, *Agent = Model + Harness* (everything besides
  the model itself — instructions, tools, sandboxes, orchestration logic,
  guardrails, observability — is "the harness"), is the direct
  articulation of this pillar.
- Karpathy, Andrej. **"From Vibe Coding to Agentic Engineering"**
  (conversation with Stephanie Zhan, Sequoia Capital *AI Ascent*, 2026).
  <https://www.youtube.com/watch?v=96jN2OCOfLs> — draws the line this
  pillar leans on directly: vibe coding (casual, ungated, "does it seem to
  work?") vs. agentic engineering (coordinated agents against a written
  spec, evals, observability, a human accountable for the result) —
  orchid is built entirely on the agentic-engineering side of that line.

### Productivity claims (stated with nuance, both directions)

Orchid makes no blanket productivity claim. The honest empirical picture is
genuinely mixed — AI coding assistance measurably speeds up some tasks and
measurably slows down others, and self-reported speed and measured speed
can diverge sharply — which is why this project states the claim with
both directions cited rather than only the flattering one:

- Becker, Joel, Nate Rush, Elizabeth Barnes, and David Rein (METR). **"
  Measuring the Impact of Early-2025 AI on Experienced Open-Source
  Developer Productivity."** arXiv:2507.09089 (2025). A randomized
  controlled trial: experienced developers using AI tools on real tasks in
  large, familiar open-source repositories took **19% longer**, despite
  forecasting a 24% speedup beforehand and believing afterward that AI had
  made them about 20% faster. <https://arxiv.org/abs/2507.09089>
- Peng, Sida, Eirini Kalliamvakou, Peter Cihon, and Mert Demirer. **"The
  Impact of AI on Developer Productivity: Evidence from GitHub Copilot."**
  arXiv:2302.06590 (2023). A controlled experiment (implementing an HTTP
  server from scratch): the group with Copilot access completed the task
  **55.8% faster**. <https://arxiv.org/abs/2302.06590>

Read together, these two results are not a contradiction to explain away —
task shape matters (a well-specified, greenfield, unfamiliar-codebase task
vs. a large, deeply familiar codebase where an experienced developer's own
tacit knowledge is the bottleneck AI assistance doesn't relieve). Orchid's
own design leans toward the conditions the first study suggests matter —
deterministic verification instead of trusting either a model's or a
developer's own sense of progress — precisely because self-reported speed
was shown to be unreliable even to the people experiencing it.

## Verification method

Every entry above was checked with a live web search/fetch during this
task, against the paper's own arXiv abstract page (or, for the two
non-arXiv items, the publisher's own listing) — not reconstructed from
training-time memory. Corrections made from the roadmap's original
design-time citation list: several venues were updated to their eventual
peer-reviewed publication (ChatDev → ACL 2024; SWE-bench → ICLR 2024;
SWE-agent → NeurIPS 2024; Mixture-of-Agents → ICLR 2025; Voyager → TMLR
2024; Reflexion/Self-Refine → NeurIPS 2023), and both the Google whitepaper
and Karpathy's framing were tracked down to a specific, dated, linkable
primary source rather than cited generically. **No citation from the
roadmap's original pillar map was dropped** — every one verified against a
real, findable, on-topic publication.
