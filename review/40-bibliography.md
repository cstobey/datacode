# Annotated bibliography — DataCode design report

Verification note: entries were checked with web search against publisher, arXiv, or author pages. Entries marked **unverified-url** have citation metadata from prior knowledge only and no URL is given. Two requested attributions were wrong in the brief and are corrected inline (Guarnieri; Fleming/Gunther/Rosebrugh).

---

## 1. Category-theoretic databases

Bears on: `docs/category-model.md` (schema as finitely presented category, four functor kinds, path equivalence), `docs/vision.md` (schema as first-class mathematical object).

**Spivak, D. I. "Functorial Data Migration." *Information and Computation* 217 (2012): 31–51. arXiv:1009.1166.** <https://arxiv.org/pdf/1009.1166>
Models a schema as a small category, an instance as a set-valued functor on it, and shows a schema morphism induces three adjoint migration functors Δ, Σ, Π.
Supports DataCode's core framing directly — `category-model.md` cites this by name for path equivalence — but note it gives migration a *three-functor adjoint* structure that DataCode's single "coercion path along the functor chain" (`evolution.md`) does not distinguish; the report should say which of Δ/Σ/Π a DataCode coercion is.

**Spivak, D. I. "Simplicial Databases." 2009. arXiv:0904.2012.** <https://arxiv.org/abs/0904.2012>
Represents a schema as a simplicial set where each simplex is a table, so nesting and joins are face and degeneracy maps.
An alternative encoding of the same intuition DataCode's component sub-tables and `group`-nesting rely on; it is the strongest available argument that nested structure need not be a second-class add-on to a categorical schema.

**Spivak, D. I., and Kent, R. E. "Ologs: A Categorical Framework for Knowledge Representation." *PLoS ONE* 7, no. 1 (2012): e24274.** <https://journals.plos.org/plosone/article?id=10.1371%2Fjournal.pone.0024274>
Presents ologs — categories whose objects and arrows carry English-readable labels — as a knowledge-representation formalism that is also a database schema.
The precedent for DataCode's claim that a schema diagram is simultaneously the ER diagram, the IDE artifact (`ide.md`), and the normative object; also the precedent for the naming discipline in the Syntax Quick Reference.

**Spivak, D. I., and Wisnesky, R. "Relational Foundations for Functorial Data Migration." *DBPL 2015*. arXiv:1212.5303.** <https://arxiv.org/abs/1212.5303> · <https://dl.acm.org/doi/10.1145/2815072.2815075>
Proves the functorial query language FQL is closed under composition and implementable in select–project–product–union relational algebra extended with key generation.
The single most load-bearing citation for DataCode's claim that "a table declaration, a query, and a derived table are one kind of thing" (`schema/queries.md`) is executable — and its *key-generation* requirement is a direct challenge to `queries.md`'s "keys are computed, never declared", since Σ-style migration mints keys the source did not have.

**Schultz, P., Spivak, D. I., Vasilakopoulou, C., and Wisnesky, R. "Algebraic Databases." *Theory and Applications of Categories* 32, no. 16 (2017): 547–619. arXiv:1602.03501.** <http://www.tac.mta.ca/tac/volumes/32/16/32-16.pdf> · <https://arxiv.org/abs/1602.03501>
Extends the set-valued-functor model with multisorted algebraic (Lawvere) theories so that concrete data — integers, strings — sits inside the categorical model rather than beside it.
This is the paper that licenses DataCode's `Text`/`Int`/`Decimal` primitives and its `type Email : Text where isValidEmail` subtyping chain to be *inside* the category rather than an escape hatch; without it the "governing monad" claim has a hole exactly where the scalars are.

**Wisnesky, R., Spivak, D. I., et al. CQL — Categorical Query Language (and its predecessor FQL).** <https://categoricaldata.net/CQL/> · <https://github.com/CategoricalData/CQL> · <https://github.com/CategoricalData/FQL>
A working IDE and engine implementing functorial data migration, uniqueness/path constraints, and chase-based instance construction over algebraic databases.
The existence proof that DataCode's approach is implementable, and the closest prior art to compare against in the report's differentiator table (`vision.md`); CQL is batch/integration-oriented, which is precisely where DataCode's OLTP-primary and distributed claims are novel rather than derivative.

**Johnson, M., Rosebrugh, R., and Wood, R. J. "Entity-Relationship-Attribute Designs and Sketches." *Theory and Applications of Categories* 10, no. 3 (2002): 94–112.** <http://www.tac.mta.ca/tac/volumes/10/3/10-03.pdf>
Formalizes EA sketches and shows database states are models of the sketch in a lextensive category.
The sketch-based tradition is the alternative to Spivak's finitely-presented-category tradition, and it handles *sums* natively — which matters for DataCode's typed-absence ADTs and `|` alternations, where a plain category with only equations is a poorer fit.

**Johnson, M., and Rosebrugh, R. "Fibrations and Universal View Updatability." *Theoretical Computer Science* 388, nos. 1–3 (2007): 109–129.** <https://www.sciencedirect.com/science/article/pii/S0304397507004835>
Shows a view update problem has a *universal* solution exactly when the view functor is a Grothendieck opfibration, giving an existence criterion rather than a heuristic.
**This is the direct challenge to `queries.md`'s "Writing through a derived table."** DataCode's three admissibility conditions (meaningful key, all joins along `:>`, all required fields projected or fixed) are a syntactic sufficient condition; Johnson–Rosebrugh give the semantic characterization, so the report should either prove DataCode's three conditions imply opfibrancy or state that they are deliberately conservative.

**Johnson, M., and Rosebrugh, R. "Lenses, Fibrations and Universal Translations." *Mathematical Structures in Computer Science* 22, no. 1 (2012): 25–42.** <https://mta.ca/~rrosebru/articles/lfut.pdf>
Introduces c-lenses, shows constant-complement view updating corresponds to a lens in the categorical database model, and that c-lenses are exactly opfibrations.
Connects the categorical account to the programming-languages lens literature (§3 below), and supplies the vocabulary for saying what DataCode's write-through *is*: a very-well-behaved lens whose `put` is decomposed by FK direction.

**Johnson, M., and Rosebrugh, R. "Constant Complements, Reversibility and Universal View Updates." *AMAST 2008*, LNCS 5140.** <https://link.springer.com/chapter/10.1007/978-3-540-79980-1_19>
Relates Bancilhon–Spyratos constant complements to reversibility and universal updates in the sketch data model.
Explains why DataCode's `where`-filter-as-check-constraint trick ("its constant equalities supply values on insert") is sound: the constant equality *is* the complement being held fixed.

**Fleming, M., Gunther, R., and Rosebrugh, R. "A Database of Categories." *Journal of Symbolic Computation* 35, no. 2 (2003): 127–135.** — **unverified-url**
A machine-readable catalogue of small categories with computed properties, built on the sketch data model.
*Correction to the brief:* this paper is a catalogue, not a statement of the sketch-based data model; the sketch data model citations you want are Johnson–Rosebrugh above. Retain this one only as evidence that "the schema is data" (a category stored in a database) has been done literally before.

---

## 2. Denotative and continuous time

Bears on: `docs/category-model.md` §Denotative Time, `docs/schema/types.md` §Behaviors, `docs/schema/queries.md` §Every query has a sample moment.

**Elliott, C., and Hudak, P. "Functional Reactive Animation." *ICFP 1997*: 263–273.** <https://dl.acm.org/doi/10.1145/258948.258973>
Introduces behaviors (continuous time-varying values) and events (time-stamped occurrences) with a denotational semantics independent of the sampling implementation.
The origin of `Behavior a ≅ Moment -> a` and of DataCode's insistence that `Moment` is a *parameter*; the paper's separation of behavior from sampling rate is exactly the argument for why `Moment` is distinct from `Timestamp` in `types.md`.

**Elliott, C. "Push-Pull Functional Reactive Programming." *Haskell Symposium 2009*.** <https://dl.acm.org/doi/10.1145/1596638.1596643> · <http://conal.net/papers/push-pull-frp/>
Combines data-driven (push) and demand-driven (pull) evaluation so reactions are near-instantaneous while continuous values are sampled only on demand.
**Both supports and challenges `distribution.md`.** It supports the "payload between servers, invalidation to clients" split — that is push for discrete events, pull for continuous values. It challenges the flat claim that "a `Behavior` cannot be pushed": push–pull's whole point is that a behavior built from reactive pieces *can* be pushed at its discrete transition points, so DataCode's statement is true only for behaviors with no reactive component.

**Elliott, C. "Denotational Design with Type Class Morphisms." LambdaPix Technical Report 2009-01, March 2009.** <http://conal.net/papers/type-class-morphisms/>
Proposes that a type's meaning function be a homomorphism for every class instance — "the instance's meaning is the meaning's instance" — as the correctness criterion for a library's design.
The methodological citation for DataCode's whole "make it feel like Haskell" tie-breaker; it is also the standard against which the `Duration`/`Period`/`Grain` split should be justified — `Period`'s non-associative calendar addition means `Period` has no `Monoid` morphism into `Duration`, which is the formal statement of why the two types cannot be merged.

**Elliott, C. "Denotational Design: From Meanings to Programs." LambdaJam / YOW! 2015 (talk).** <http://conal.net/talks/denotational-design-lambdajam-2015.pdf>
Working method: fix the denotation first, derive the API and its laws from it, and treat any operation with no denotation as a design error.
The practice behind DataCode's rule that a functor must be transparent and a behavior must be total from `created_at` onward.

**Hughes, J. "Generalising Monads to Arrows." *Science of Computer Programming* 37, nos. 1–3 (2000): 67–111.** <https://www.sciencedirect.com/science/article/pii/S0167642399000234>
Generalizes monads to arrows, permitting static analysis of a computation's structure before it runs.
The formal precedent for DataCode's central bet in `dynamic-loading.md`: a term you can *walk* buys optimizer, access analysis, coercion derivation, and diagram rendering, which a closure does not.

**Nilsson, H., Courtney, A., and Peterson, J. "Functional Reactive Programming, Continued." *Haskell Workshop 2002*: 51–64.** <https://dl.acm.org/doi/10.1145/581690.581695>
Arrowized FRP: signal functions rather than first-class signals, which eliminates the space leaks of first-class behaviors and makes the dataflow graph statically inspectable.
Undercuts nothing in DataCode but reframes a choice: DataCode's behaviors *are* first-class (`Behavior a` is a field type), and AFRP is the standard argument that this leaks; DataCode escapes the leak only because behaviors are recomputed per query from stored fields rather than retained, and the report should say so explicitly.

**Bärenz, M., and Perez, I. "Rhine: FRP with Type-Level Clocks." *Haskell Symposium 2018*.** <https://dl.acm.org/doi/10.1145/3242744.3242757>
Puts clocks in the type system so that composing two signal networks running at different rates requires an explicit, type-checked resampling buffer.
The strongest available support for `queries.md`'s rule that "the coordinating server resolves the sample moment once, and every shard evaluates against the value it was given" — Rhine's clock-safety is precisely the property that shards independently reading "now" would violate, and its type-level treatment suggests DataCode's `Moment`/`Timestamp` distinction could be strengthened to a clock index.

---

## 3. Relational and dependency theory; the view-update problem

Bears on: `docs/schema/queries.md` §Keys are computed, never declared and §Writing through a derived table; `docs/schema/tables.md`.

**Codd, E. F. "A Relational Model of Data for Large Shared Data Banks." *CACM* 13, no. 6 (1970): 377–387.** <https://cacm.acm.org/research/a-relational-model-of-data-for-large-shared-data-banks-2/>
Establishes n-ary relations, data independence from physical representation, and normal form.
The baseline `vision.md` positions against; note that Codd's *data independence* argument is the same one DataCode makes for materialization in `storage.md`, so the contrast in the differentiator table is about foundation, not about that goal.

**Armstrong, W. W. "Dependency Structures of Data Base Relationships." *Proc. IFIP Congress 1974*: 580–583.** — **unverified-url**
Gives the sound and complete axiomatization of functional dependencies (reflexivity, augmentation, transitivity).
The formal basis for two rules in `queries.md`: that a superkey of a declared candidate key reduces to it, and that FK substitution yields a *minimal* rather than merely correct key. The report's key-propagation table is an FD closure computation and should be presented as one.

**Fagin, R. "Multivalued Dependencies and a New Normal Form for Relational Databases." *ACM TODS* 2, no. 3 (1977): 262–278.** <https://dl.acm.org/doi/10.1145/320557.320571>
Introduces multivalued dependencies and 4NF, showing lossless decomposition beyond what FDs alone justify.
Bears on `group`: DataCode's `group` nests rather than aggregates away, so `group { customer }` is exactly an MVD-respecting nest, and the claim "nothing is discarded and there is precisely one output row per distinct key" is a 4NF statement in disguise.

**Chandra, A. K., and Merlin, P. M. "Optimal Implementation of Conjunctive Queries in Relational Data Bases." *STOC 1977*: 77–90.** <https://dl.acm.org/doi/10.1145/800105.803397>
Proves conjunctive-query containment is NP-complete and that every conjunctive query has a unique minimal equivalent.
The decidability result that DataCode's static access analysis depends on: `category-model.md` claims access rules "can be statically analyzed for consistency (no contradictions, no gaps)", and this is the theorem that makes that tractable *only* because asserts are rooted at `self` and therefore conjunctive.

**Maier, D., Mendelzon, A. O., and Sagiv, Y. "Testing Implications of Data Dependencies." *ACM TODS* 4, no. 4 (1979): 455–469.** <https://dl.acm.org/doi/10.1145/320107.320115>
Introduces the chase as a uniform procedure for deciding implication among data dependencies.
The chase is how CQL computes Σ migrations and how a constraint set is checked for redundancy; DataCode's "walk the affected subgraph and verify all declared constraints still hold" (`category-model.md`) is a bounded chase, and naming it as such makes the termination argument the rootedness restriction already provides.

**Bancilhon, F., and Spyratos, N. "Update Semantics of Relational Views." *ACM TODS* 6, no. 4 (1981): 557–575.** — **unverified-url**
Defines a view update as translatable exactly when a *complement* of the view is held constant, and shows the translation is then unique.
The origin of the constant-complement criterion, and the reason DataCode's write-through rules are sound: the projected-away columns are the complement, and "every required field is projected or fixed by the `where`" is the constant-complement condition restated in schema terms.

**Gottlob, G., Paolini, P., and Zicari, R. "Properties and Update Semantics of Consistent Views." *ACM TODS* 13, no. 4 (1988): 486–524.** <https://dl.acm.org/doi/10.1145/49346.50068>
Models databases and views as abstract data types with state sets and primitive update operators, and characterizes when a view's updates are *consistent* — a weaker and more usable condition than constant complement.
Directly relevant to `queries.md`'s `delete` rule ("removes the row the key identifies, and never cascades"): consistency, not constant complement, is what that rule satisfies, and the doc's own admission that "delete the service account reads as though the user should go too" is the classic consistent-but-surprising case this paper analyzes.

**Foster, J. N., Greenwald, M. B., Moore, J. T., Pierce, B. C., and Schmitt, A. "Combinators for Bidirectional Tree Transformations: A Linguistic Approach to the View-Update Problem." *ACM TOPLAS* 29, no. 3 (2007): article 17.** <https://dl.acm.org/doi/10.1145/1232420.1232424>
Introduces lenses — paired `get`/`put` transformations — with well-behavedness laws (PutGet, GetPut) enforced by a type system over combinators.
Gives DataCode the laws its write-through must satisfy and, more usefully, the *compositional* structure: since DataCode's derived tables are built from a small operator set (`where`, `{…}`, `><`, `group`, `|`), each operator should carry a lens, and write-through admissibility should be derived by composition rather than checked by three ad hoc conditions.

**Bohannon, A., Pierce, B. C., and Vaughan, J. A. "Relational Lenses: A Language for Updatable Views." *PODS 2006*: 338–347.** <https://dl.acm.org/doi/10.1145/1142351.1142399>
Adapts lenses to relational select/project/join, with functional-dependency side conditions determining when each operator is updatable.
The closest existing match to DataCode's per-operator key-propagation table; its FD side conditions on join and project are essentially DataCode's "lossless along a `:>` edge" and "degenerate if a key column is projected away", which is strong independent confirmation that the table is right.

**Horn, R., Perera, R., and Cheney, J. "Incremental Relational Lenses." *ICFP 2018* / *PACMPL* 2. arXiv:1807.01948.** <https://dl.acm.org/doi/10.1145/3236769>
Makes relational lenses incremental so a view update costs work proportional to the change, not to the extent.
Directly supports `storage.md`'s "refresh is incremental only with a meaningful key" — and shows the converse is a theorem, not a limitation: the change-propagation function needs a key to identify what moved.

---

## 4. Query languages over nested data

Bears on: `docs/schema/queries.md` §Grouping, `docs/schema/documents.md`, `docs/storage.md` §Shredded Documents.

**Jaeschke, G., and Schek, H.-J. "Remarks on the Algebra of Non First Normal Form Relations." *PODS 1982*: 124–138.** — **unverified-url**
Introduces set-valued attributes with `nest` and `unnest` as the restructuring operators of a nested relational algebra.
`group` is `nest` with a projection deciding the key, and the residual `rows` column is the set-valued attribute; the report should name this lineage rather than presenting `group` as new.

**Buneman, P., Libkin, L., Suciu, D., Tannen, V., and Wong, L. "Comprehension Syntax." *ACM SIGMOD Record* 23, no. 1 (1994): 87–96.** <https://dl.acm.org/doi/10.1145/181550.181564>
Argues comprehension syntax over collection types is a better basis for query languages than first-order logic, and is a natural fragment of structural recursion.
The argument that DataCode's "aggregate functions are ordinary functions applied to a table, never a postfix keyword" is principled rather than stylistic — `count :: Table a -> Int` is exactly the collection-type discipline, and it is what makes `count $ Orders group { customer }` compose.

**Buneman, P., Naqvi, S., Tannen, V., and Wong, L. "Principles of Programming with Complex Objects and Collection Types." *Theoretical Computer Science* 149, no. 1 (1995): 3–48.** <https://www.sciencedirect.com/science/article/pii/030439759500024Q>
Establishes the conservativity results for nested relational calculi — nesting adds no expressive power at flat input/output types, but adds convenience and can change complexity.
Important caution for DataCode: conservativity means `group`'s nesting is not buying expressiveness, so its justification must be the one `queries.md` actually gives (exactness — nothing is discarded), not power.

**Cheney, J., Lindley, S., and Wadler, P. "A Practical Theory of Language-Integrated Query." *ICFP 2013*: 403–416.** <https://dl.acm.org/doi/10.1145/2500365.2500586>
Shows quotation plus normalization of quoted terms guarantees that a well-typed host-language query compiles to a *single* SQL query, supporting abstraction over predicates and dynamic query generation.
The strongest precedent for DataCode's interpreted-DSL choice in `dynamic-loading.md`: a normalizable term language gives both the static guarantee and the dynamic composition that "queries compose" (`queries.md`) claims, and the normalization theorem is the missing piece in DataCode's current account of what the optimizer is allowed to do.

**Cheney, J., Lindley, S., and Wadler, P. "Query Shredding: Efficient Relational Evaluation of Queries over Nested Multisets." *SIGMOD 2014*: 1027–1038. arXiv:1404.7078.** <https://dl.acm.org/doi/10.1145/2588555.2612186> · <https://arxiv.org/abs/1404.7078>
Translates a query returning nested data into a fixed number of flat SQL queries whose results are stitched back into the nested shape, with multiset semantics preserved.
Bears two ways. It is the theory behind `documents.md`'s shredding, and it is the *engineering* answer for how a chained `group` is executed. It also mildly undercuts `storage.md`'s "one range scan" claim: shredding's cost model is a fixed number of queries per nesting level, so the single-seek property depends entirely on the clustering invariant `storage.md` states, and is not a property of shredding itself.

**Smith, J., Benedikt, M., et al. "Scalable Querying of Nested Data." *PVLDB* 14, no. 3 (2020): 445–457.** <https://doi.org/10.14778/3430915.3430933>
Shows shredding-based nested query evaluation scaling on distributed engines, with cost models for when to shred versus keep nested.
The distributed counterpart, relevant to `distribution.md`'s "broadcast a query plan fragment to neighbors, merge contributions" — it is the closest prior work on when that merge is cheaper than shipping nested results.

---

## 5. Distributed systems

Bears on: `docs/distribution.md` throughout, `docs/transaction-graph.md`.

**Lamport, L. "Time, Clocks, and the Ordering of Events in a Distributed System." *CACM* 21, no. 7 (1978): 558–565.** <https://dl.acm.org/doi/10.1145/359545.359563>
Defines the happens-before partial order, gives a logical-clock algorithm to totally order events, and bounds physical clock skew.
The reason `distribution.md`'s clock-regression clamping and per-server wall clocks are a hazard worth the paragraph they get: DataCode's sequence numbers are per-shard logical clocks, and `DataId`'s time-major ordering is a physical clock doing a logical clock's job across shards.

**Gray, J., and Lamport, L. "Consensus on Transaction Commit." *ACM TODS* 31, no. 1 (2006): 133–160.** <https://dl.acm.org/doi/10.1145/1132863.1132867>
Presents Paxos Commit, which runs a Paxos instance per participant's prepare/abort vote, tolerating F coordinator failures with 2F+1 coordinators; classic 2PC is the F = 0 case.
**The direct challenge to `distribution.md`'s cross-shard protocol.** DataCode's prepared-node-per-participant plus one commit node is 2PC with the coordinator being "whichever server accepted the mutation" — i.e. exactly the F = 0 case, and therefore blocking on coordinator failure. `vision.md` names this as a deliberate non-goal, but the report should cite Gray–Lamport for what is being given up and note that DataCode's escape ("a prepared node excludes nothing, so the only outcome is an abort") makes it non-blocking for *others* while still leaving the initiator's transaction in doubt.

**Alvaro, P., Conway, N., Hellerstein, J. M., and Marczak, W. R. "Consistency Analysis in Bloom: A CALM and Collected Approach." *CIDR 2011*: 249–260.** <https://people.ucsc.edu/~palvaro/cidr11.pdf>
Introduces Bloom, a disorderly declarative language whose analysis flags non-monotonic operators as the points where coordination is required.
The template for a static analysis DataCode does not yet have: `distribution.md` decides coordination need by *shard crossing*, whereas CALM decides it by *monotonicity*, and DataCode's append-only, nothing-is-destroyed graph is unusually monotone — an assert that is a rooted non-emptiness test is monotone and needs no coordination; its negation is not and does.

**Hellerstein, J. M., and Alvaro, P. "Keeping CALM: When Distributed Consistency Is Easy." *CACM* 63, no. 9 (2020): 72–81. arXiv:1901.01930.** <https://dl.acm.org/doi/10.1145/3369736> · <https://arxiv.org/abs/1901.01930>
States and explains the CALM theorem: a program has a consistent coordination-free distributed implementation exactly when it is expressible in monotonic logic.
Bears on `distribution.md`'s "constraints that cross shards cannot promise `enforce always`" — CALM says the same thing from the other direction and more sharply: the *negative* assertion is the non-monotone one, so the restriction should key on assert polarity as well as on shard crossing.

**Shapiro, M., Preguiça, N., Baquero, C., and Zawirski, M. "Conflict-Free Replicated Data Types." *SSS 2011*, LNCS 6976: 386–400 (INRIA RR-7687).** <https://link.springer.com/chapter/10.1007/978-3-642-24550-3_29>
Defines strong eventual consistency and shows join-semilattice (state-based) or commutative (op-based) replicated types converge without coordination or rollback.
Supports `schema/aggregates.md`'s requirement that a retention-chain aggregate declare an associative merge with an identity — that is a commutative monoid, which is the CRDT condition; it also undercuts `connectors.md`'s "timestamp last-write-wins (last resort)", since LWW is the CRDT the literature specifically warns loses writes.

**Kleppmann, M., and Beresford, A. R. "A Conflict-Free Replicated JSON Datatype." *IEEE TPDS* 28, no. 10 (2017): 2733–2746.** <https://www.cl.cam.ac.uk/~arb33/papers/KleppmannBeresford-CRDT-JSON-TPDS2017.pdf>
Gives a CRDT with formal semantics for arbitrarily nested maps and lists, resolving concurrent edits at the tree-node level.
Relevant to `documents.md`'s shredded `Doc` node tree: it is the reference design for merging two versions of a shredded document, which DataCode's connector conflict resolution currently handles only at whole-row granularity.

**Thomson, A., Diamond, T., Weng, S.-C., Ren, K., Shao, P., and Abadi, D. J. "Calvin: Fast Distributed Transactions for Partitioned Database Systems." *SIGMOD 2012*: 1–12.** <https://dl.acm.org/doi/abs/10.1145/2213836.2213838>
Orders transactions deterministically *before* execution, so replicas execute the same sequence independently and distributed commit needs no agreement protocol at commit time.
The most direct alternative to DataCode's design and worth confronting: Calvin gets cross-shard transactions without 2PC by paying the cost DataCode refuses (the full read/write set must be known in advance) — and `distribution.md` already concedes that this is undecidable for interactive transactions, which is exactly the right rebuttal to state.

**Corbett, J. C., Dean, J., et al. "Spanner: Google's Globally-Distributed Database." *OSDI 2012*; *ACM TOCS* 31, no. 3 (2013): article 8.** <https://www.usenix.org/system/files/conference/osdi12/osdi12-final-16.pdf>
Achieves external consistency for globally distributed transactions using TrueTime — bounded-uncertainty clocks — and commit-wait, plus Paxos-replicated shards.
Challenges DataCode's sample-moment design at its weakest point: Spanner needs a bounded-uncertainty clock to make "as of time T" globally meaningful, and DataCode resolves the moment at one coordinator instead, which is correct for a single query but gives no external-consistency guarantee *between* two queries served by different coordinators.

**Kreps, J. "The Log: What Every Software Engineer Should Know About Real-Time Data's Unifying Abstraction." LinkedIn Engineering, 2013.** <https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying>
Argues an append-only totally ordered log is the primitive from which replication, derived state, and stream processing all follow.
The industrial statement of DataCode's architecture: the transaction log is the source of truth and every index, materialized view, and rollup is derived state — `storage.md`'s two-structures-per-shard design is this idea applied per shard.

**Kleppmann, M. *Designing Data-Intensive Applications*. O'Reilly, 2017.** <https://dataintensive.net/>
Survey of replication, partitioning, transactions, consensus, and derived data, with a sustained argument for logs and change streams as the unifying substrate.
The best single citation for the "derived data" framing that `storage.md`'s materialization section assumes, and for the partitioning/rebalancing tradeoffs behind `distribution.md`'s shard-split thresholds.

---

## 6. Storage and formats

Bears on: `docs/storage.md`, `docs/tech-stack.md` §Storage and §Serialization.

**Chu, H. "The Lightning Memory-Mapped Database (LMDB)." SNIA Storage Developer Conference, 2015; and Henry, W. "Howard Chu on Lightning Memory-Mapped Database." *IEEE Software* 36, no. 6 (2019).** <https://www.snia.org/sites/default/files/SDC15_presentations/database/HowardChu_The_Lighting_Memory_Database.pdf> · <https://ieeexplore.ieee.org/document/8880032/>
Describes LMDB's copy-on-write B+tree with two root pages, single-writer MVCC, memory-mapped reads with no buffer pool, and crash safety without a WAL.
The primary source for every LMDB property `tech-stack.md` and `storage.md` rely on — readers never block writers, no separate WAL, sorted keys giving contiguous range scans — and for the cross-process writer lock that `dynamic-loading.md` uses as the generation-swap handover primitive.

**O'Neil, P., Cheng, E., Gawlick, D., and O'Neil, E. "The Log-Structured Merge-Tree (LSM-Tree)." *Acta Informatica* 33, no. 4 (1996): 351–385.** <https://dl.acm.org/doi/10.1007/s002360050048>
Presents the LSM-tree: buffer writes in memory, merge sorted runs to disk, trading read amplification for a large write-throughput gain over B-trees.
The exact tradeoff `tech-stack.md` invokes to rule out RocksDB — and the doc's reasoning is right for the stated reason: the append-only log already absorbs the write path, so the LSM write advantage would be paid for twice while the read amplification would be paid for once.

**Crotty, A., Leis, V., and Pavlo, A. "Are You Sure You Want to Use MMAP in Your DBMS?" *CIDR 2022*.** <https://www.pdl.cmu.edu/ftp/Database/p13-crotty.pdf>
Catalogues four problems with mmap in a DBMS — transactional safety against page-cache writeback, unpredictable I/O stalls, error handling, and TLB shootdown costs under concurrency — and measures the performance cliff.
**The most important challenge in this bibliography to `storage.md`'s "Full Zero-Copy Read Path."** Three of the four objections are neutralized by DataCode's design (the log is append-only and never written through the map; LMDB owns its own durability), but the fourth is not: TLB shootdown and page-fault stalls apply to DataCode's mmap'd Cap'n Proto log directly, and the report should say so rather than cite the 11µs read as if it settled the question. Note also that `dynamic-loading.md` already flags GHC-on-node evicting the page cache — that is the same hazard from a different direction.

**Varda, K. Cap'n Proto — serialization protocol and encoding specification.** <https://capnproto.org>
Defines a wire format identical to the in-memory layout, so there is no encode/decode step, plus a pointer-and-offset scheme giving forward and backward compatible field addition.
The source for `tech-stack.md`'s claim that adding a `TxNode` field is compatible in both directions at 8 bytes and needs no version byte, and for the contrast with Protobuf, which requires full parsing.

---

## 7. Immutable and temporal data

Bears on: `docs/transaction-graph.md`, `docs/storage.md` §Compaction Is Lossless, `docs/schema/queries.md` §Historical queries.

**Hickey, R. "Deconstructing the Database." QCon San Francisco / JaxConf, 2012 (talk).** <https://qconsf.com/sf2012/dl/qcon-sanfran-2012/slides/RichHickey_DeconstructingTheDatabase.pdf> · Datomic architecture: <https://docs.datomic.com/pro/overview/architecture.html>
Argues a database is a value — an accretion of immutable `[entity attribute value transaction]` facts — and decomposes the monolith into separate transaction, storage, and query services.
The closest architectural relative to DataCode and the strongest support for "nothing is destroyed", "a query is pegged to a point", and the separation of the write-serializing transactor from read-serving peers; the divergence to name is that Datomic's transactor is global while DataCode's primary is per shard.

**Snodgrass, R. T. *Developing Time-Oriented Database Applications in SQL*. Morgan Kaufmann, 1999.** <https://onlinebooks.library.upenn.edu/webbin/book/lookupid?key=olbp93636>
Practical treatment of valid time and transaction time in SQL, including temporal constraints, coalescing, and temporal joins.
The reference for the *bitemporal* distinction DataCode blurs: `Timestamp` and the transaction graph give transaction time, `Moment` gives observation time, but valid time — "when was this fact true in the world" — has no home in the current model, and connector-sourced data will need it.

**Date, C. J., Darwen, H., and Lorentzos, N. *Temporal Data and the Relational Model*. Morgan Kaufmann, 2002; 2nd ed. as *Time and Relational Theory*, Morgan Kaufmann, 2014.** <https://www.sciencedirect.com/book/9780128006313/time-and-relational-theory>
Builds temporal support from interval types and interval-aware relational operators (`PACK`, `UNPACK`, `U_` operators) rather than from special-case syntax.
Bears on `schema/aggregates.md`'s `Grain` forest: Date et al. argue interval granularity must be part of the type, which is precisely DataCode's `Grain`-declares-its-alignment rule, and their treatment of why intervals at different granularities do not compose is the general form of the `IsoWeek → Month` prohibition.

**Fowler, M. "Event Sourcing." martinfowler.com, 2005.** <https://martinfowler.com/eaaDev/EventSourcing.html>
Stores all state changes as an ordered sequence of events so that any past state is reconstructible and retroactive correction is possible by replay.
The practitioner-facing name for DataCode's version chain; its "retroactive events" discussion is the closest prior treatment of `integrity.md`'s reified violations — a rule introduced after the data, discharged by changing either side.

**Apache Accumulo — cell-level security (column visibility).** <https://accumulo.apache.org/1.4/user_manual/Security.html>
Attaches a boolean visibility expression to every key–value pair and evaluates it against the requester's authorizations at scan time.
The production precedent for access control evaluated on the read path at row granularity, which is what DataCode's access asserts do — and the counter-example for granularity: Accumulo goes to the cell, DataCode stops at the row and resolves a failed read to `Redacted`.

---

## 8. Access control as row-level security

Bears on: `docs/auth.md` §Access Control Functors, `docs/category-model.md` §Path Constraint Functors.

**Rizvi, S., Mendelzon, A. O., Sudarshan, S., and Roy, P. "Extending Query Rewriting Techniques for Fine-Grained Access Control." *SIGMOD 2004*: 551–562.** <https://dl.acm.org/doi/abs/10.1145/1007568.1007631>
Defines authorization views and an "authorization-transparent" model where a user query phrased against base relations is accepted only if it is answerable from the authorization views, using query-containment reasoning.
The formal statement of what DataCode's access asserts do. It supports the claim that authorization is the same machinery as data constraints — both reduce to containment — and it names the cost: the *Truman* versus *non-Truman* distinction. DataCode is a Truman model (silently filtered, `Redacted` substituted), and Rizvi et al. show Truman models can return misleading answers to aggregate queries; the report must address this.

**Guarnieri, M., Marinovic, S., and Basin, D. "Strong and Provably Secure Database Access Control." *IEEE EuroS&P 2016*. arXiv:1512.01479.** <https://arxiv.org/abs/1512.01479>
Gives an attacker model and a security definition for database access control, shows that mainstream SQL systems' mechanisms are attackable through integrity constraints and error messages, and presents a provably secure enforcement mechanism.
*Correction to the brief:* the second author is Marinovic, not Marzuoli. **This is the sharpest challenge to `auth.md`.** Its central attack is inference through *integrity constraints and error messages* — and DataCode has both in abundance: a `unique` violation on a hidden row, an `assert` failure naming a path, and `integrity.md`'s violation records all leak the existence of rows a token cannot read. `types.md`'s `Secret` diagnostics erasure closes one channel of exactly this class; the others are open.

**Goguen, J. A., and Meseguer, J. "Security Policies and Security Models." *IEEE Symposium on Security and Privacy*, 1982: 11–20.** — **unverified-url**
Defines non-interference: low-clearance observations must be independent of high-clearance inputs.
The standard against which the aggregate-leakage problem is stated — a row-level filter is non-interfering only if no aggregate a token may compute varies with rows it may not see, which DataCode's `count rows` over an access-filtered `group` does not satisfy.

**PostgreSQL — Row Security Policies and `CREATE POLICY`.** <https://www.postgresql.org/docs/current/ddl-rowsecurity.html> · <https://www.postgresql.org/docs/current/sql-createpolicy.html>
Per-table policies with a `USING` expression filtering visible rows and a `WITH CHECK` expression constraining written rows, applied per command type.
The closest deployed analogue to DataCode's access asserts, and the source of an idea DataCode should adopt explicitly: PostgreSQL's `USING`/`WITH CHECK` split is the read-time/write-time distinction that `category-model.md` derives ("an access constraint runs on read as well"), already validated in production.

**Oracle — Virtual Private Database (VPD) / Fine-Grained Access Control, `DBMS_RLS`.** <https://docs.oracle.com/cd/B13789_01/network.101/b10773/apdvcntx.htm>
Attaches a policy function to a table that returns a predicate, which the optimizer appends to every statement at parse time, driven by an application context.
The oldest production instance of the query-rewriting approach and the source of its known failure modes — policy functions that read the clock or perform I/O, and predicate composition that surprises — both of which DataCode structurally forbids via the missing `Effect` lift, which is a genuine differentiator worth stating.

---

## 9. Types and DSLs in Haskell

Bears on: `docs/dynamic-loading.md`, `docs/schema/functions.md` §The Effect Ladder, `docs/schema/types.md`.

**Xi, H., Chen, C., and Chen, G. "Guarded Recursive Datatype Constructors." *POPL 2003*: 224–235.** <https://dl.acm.org/doi/10.1145/604131.604150>
Introduces guarded recursive datatypes (GADTs), where each constructor may refine the type index, enabling type-safe interpreters for object languages.
The mechanism `dynamic-loading.md` chose: `Term ctx eff a` with the effect index refined per constructor is a GADT in exactly this sense, and the "absent `Effect` constructor" trick is index refinement doing the work a signature check could not.

**Carette, J., Kiselyov, O., and Shan, C. "Finally Tagless, Partially Evaluated: Tagless Staged Interpreters for Simpler Typed Languages." *JFP* 19, no. 5 (2009): 509–543.** <https://okmij.org/ftp/tagless-final/JFP.pdf>
Encodes a typed object language as overloaded combinator functions rather than data constructors, allowing multiple interpretations (evaluate, compile, partially evaluate) without GADTs or tags.
**The main alternative to DataCode's chosen encoding, and it undercuts one stated reason for it.** `dynamic-loading.md` justifies the GADT by transparency — four consumers need the term's structure — but tagless-final gets multiple interpretations *for free* by adding interpreter instances, which is a better fit for "assert-variety classification, `bypass access` exemption set, anchoring, shard-crossing detection" than pattern-matching one walk per analysis. The counter-argument DataCode has and should make explicit: a tagless-final term is a function, so it is not a content-addressed graph node, and the replay requirement kills it.

**Bird, R., and Paterson, R. "De Bruijn Notation as a Nested Datatype." *JFP* 9, no. 1 (1999): 77–91.** <https://www.staff.city.ac.uk/~ross/papers/debruijn.html>
Represents lambda terms with de Bruijn indices as a nested (non-regular) datatype so that scoping errors are type errors.
The technique behind the `ctx` index in DataCode's `Term '[] eff a` — a functor term is well-scoped in its parameter context by construction, which is what makes "functors are terms in a context of their parameters — no Haskell closure" (`dynamic-loading.md`) sound.

**Swierstra, W. "Data Types à la Carte." *JFP* 18, no. 4 (2008): 423–436.** <https://www.cambridge.org/core/journals/journal-of-functional-programming/article/data-types-a-la-carte/14416CB20C4637164EA9F77097909409>
Composes datatypes as coproducts of functors with a subtyping class, so new constructors and new interpretations can be added independently.
The standard answer to the expression problem, and the natural implementation route for `schema/traits.md`'s `Extensible` trait — a connector adding a variant to a `Reference` table is a coproduct injection — as well as for the open `Null`-rooted absence family in `types.md`.

**Kiselyov, O., Sabry, A., and Swords, C. "Extensible Effects: An Alternative to Monad Transformers." *Haskell Symposium 2013*: 59–70.** <https://dl.acm.org/doi/10.1145/2578854.2503791>
Represents effects as an open union interpreted by handlers, so effects compose without a fixed transformer ordering.
Relevant to the shape of `Pure`/`Read`/`Tx`/`Effect`: DataCode's ladder is a fixed total order, which is simpler and buys the "missing lift" invariant, but the report should note that the open-union alternative would make `Effect` capabilities (reachable hosts, credentials, timeouts, per `dynamic-loading.md`) into typed effect rows rather than a `Configuration` row checked at runtime.

**Plotkin, G., and Pretnar, M. "Handlers of Algebraic Effects." *ESOP 2009*, LNCS 5502: 80–94.** <https://link.springer.com/chapter/10.1007/978-3-642-00590-9_7>
Generalizes exception handlers to all algebraic effects, so an effectful term is interpreted by an algebra chosen at the handling site.
The theory that makes `integrity.md`'s "enforcement mode is a property of the attachment, not of the functor" precise — the functor raises, the attachment handles, and `enforce`/`monitor`/`repair into` are three algebras for one signature. This is the cleanest formal justification available for that design and is currently uncited.

---

## 10. Regular expressions, hashing, and cryptography

Bears on: `docs/schema/types.md` §Secret/Hashed/Encrypted, `docs/auth.md`, `docs/distribution.md` §The `unique` Index Holds Digests, `docs/tech-stack.md`.

**Cox, R. "Regular Expression Matching Can Be Simple and Fast." 2007; and "Regular Expression Matching in the Wild" (RE2), 2010.** <https://swtch.com/~rsc/regexp/regexp1.html> · <https://research.swtch.com/regexp3>
Shows Thompson NFA simulation and lazy DFA construction match in time linear in input × pattern, while backtracking engines are exponential on adversarial patterns, and describes the production RE2 implementation.
The justification for `Text.Regex.TDFA` in `tech-stack.md` — TDFA is a DFA engine, so `=~` cannot be a ReDoS vector. This matters more than the doc says: a regex in a validation functor runs on the commit path with attacker-supplied input, so a backtracking engine would be a denial-of-service surface, and the still-unrun spike (`dynamic-loading.md`) leaves this unvalidated.

**Biryukov, A., Dinu, D., Khovratovich, D., and Josefsson, S. "Argon2 Memory-Hard Function for Password Hashing and Proof-of-Work Applications." RFC 9106, IRTF CFRG, September 2021.** <https://www.rfc-editor.org/info/rfc9106/> · <https://datatracker.ietf.org/doc/html/rfc9106>
Specifies Argon2d/i/id with recommended memory, time, and parallelism parameters; Argon2 won the 2015 Password Hashing Competition.
The source for `system.crypto.HashPolicy`'s columns — `memory_kib`, `iterations`, `parallelism`, `salt_bytes` are Argon2's parameters exactly — and the reason `types.md` is right to make them a queryable `Reference` row: RFC 9106's recommendations are explicitly expected to move with hardware.

**NIST. *Digital Identity Guidelines: Authentication and Lifecycle Management*. NIST SP 800-63B.** <https://pages.nist.gov/800-63-3/sp800-63b.html>
Requires verifiers to check prospective memorized secrets against breach corpora and common-password lists, sets a minimum length, and advises against composition rules and routine expiry.
`auth.md` cites this correctly for "length plus breach-list checking" over composition rules. **Caution for the report:** the SP 800-63-3 revision linked here is superseded — SP 800-63B-4 was published in 2025 — so the citation should be to the current revision, and the "at least 8 characters" figure should be re-checked against it.

**Valsorda, F., et al. "age Encryption Format," version 1 (C2SP specification).** <https://c2sp.org/age@v1.1.0>
Specifies a file encryption format with X25519 recipient stanzas wrapping a per-file key, plus an SSH recipient type that maps an Ed25519 identity to X25519 via the birational map.
The exact construction `auth.md` describes for wrapping one data key to many server public keys, including the subtlety the doc flags — `ssh-ed25519` is a signing key and reaches encryption only through the birational map.

**Bernstein, D. J., et al. "Elliptic Curves for Security." RFC 7748 (X25519).** — **unverified-url**
Specifies Curve25519 and the X25519 Diffie–Hellman function, including the all-zeroes output check.
The primitive under the age recipient stanza; cite it as the normative definition rather than relying on the age spec alone.

**Aumasson, J.-P., and Bernstein, D. J. "SipHash: A Fast Short-Input PRF." *INDOCRYPT 2012*, LNCS 7668: 489–508. IACR ePrint 2012/351.** <https://eprint.iacr.org/2012/351> · <https://link.springer.com/chapter/10.1007/978-3-642-34931-7_28>
A fast keyed PRF for short inputs, designed so that an attacker without the key cannot produce collisions — the defence against hash-flooding.
**The right primitive for two DataCode designs, and the report should name it.** `distribution.md`'s digest-only `unique` index needs a *keyed* digest partitioned by digest value, which is SipHash's exact use case; `auth.md`'s `AttemptDigest` needs a keyed deterministic digest with a cluster-wide key. Note the caveat `auth.md` already states — SipHash is fast, so a leaked key makes the attempt table offline-dictionary-attackable, which is why the 90-day retention is load-bearing.

**Krawczyk, H., Bellare, M., and Canetti, R. "HMAC: Keyed-Hashing for Message Authentication." RFC 2104, 1997.** — **unverified-url**
Defines HMAC and proves it a secure MAC given a suitable compression function.
The primitive behind `connectors.md`'s webhook signature verification, and the reason `storage.md` keeps received `Doc` bytes verbatim rather than reserializing a shredded tree — HMAC is over the exact byte sequence.

---

## 11. Streaming ingest and change data capture

Bears on: `docs/connectors.md`, `docs/events.md`.

**Oracle/MySQL. "Replication with Global Transaction Identifiers." *MySQL 8.0 Reference Manual* §19.1.3; MariaDB. "Global Transaction ID."** <https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-concepts.html> · <https://mariadb.com/docs/server/ha-and-performance/standard-replication/gtid>
A GTID uniquely identifies a committed transaction across the whole topology; a replica that has already applied a GTID ignores a repeat, which gives idempotent apply and position-independent failover.
**A concrete improvement to `connectors.md`.** DataCode currently checkpoints "the binlog filename and offset (from `getLastBinLogTracker`)", which is the *pre-GTID* mechanism: it does not survive a source failover to a different server and cannot detect a re-delivered transaction. GTIDs give exactly the at-most-once apply the connector wants, and the report should flag this as an open item against `mysql-haskell`'s API.

**Debezium — connector architecture and FAQ; "Reliable Microservices Data Exchange with the Outbox Pattern," 2019.** <https://debezium.io/documentation/faq/> · <https://debezium.io/blog/2019/02/19/reliable-microservices-data-exchange-with-the-outbox-pattern/>
Debezium tails database logs, emits per-row change events preserving source order, and offers at-least-once by default with exactly-once support in recent releases; the outbox pattern writes the event to a table in the same transaction as the business update, eliminating the dual write.
Two bearings. The outbox pattern is precisely DataCode's event functor — "an external side effect is reified as data (a queue row) that later processing consumes" (`category-model.md`) — arrived at independently, which is strong corroboration. And Debezium's default of at-least-once is the reason `connectors.md`'s "rules over connector-sourced data default to `monitor`" is right: an at-least-once stream will redeliver, and a stream that halts on a malformed row halts permanently.

**Kreps, J., Narkhede, N., and Rao, J. "Kafka: A Distributed Messaging System for Log Processing." *NetDB 2011*.** — **unverified-url**
A partitioned, replicated commit log with consumer-tracked offsets, giving ordered delivery per partition and replay from an arbitrary position.
The reference model for "deltas since sequence N" in `distribution.md`'s announce-and-fetch path: the consumer-tracked-offset design is why one protocol serves both a lagging tertiary and a reconnecting client, and Kafka's per-partition-only ordering guarantee is the same limitation DataCode accepts per shard.