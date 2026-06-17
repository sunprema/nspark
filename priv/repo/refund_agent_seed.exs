# Real-world prompt → studio graph.
#
#     mix run priv/repo/refund_agent_seed.exs
#
# Models a genuinely complicated production system prompt — a regulated fintech
# refund & dispute support agent — as a Newtonian Spark graph. Exercises every
# consumer/provider node type plus a conditional branch (whose variables should
# fall out as *optional* in the published contract).
#
# The original prompt this decomposes is reproduced in REFUND_AGENT_PROMPT.md.

import Ash.Query, only: [filter: 2]

alias Nspark.Accounts.Organization
alias Nspark.Projects.Project
alias Nspark.Architecture.{Graph, Node, Edge}

org =
  case Organization |> filter(slug == "nspark-demo") |> Ash.read!() do
    [org | _] -> org
    [] -> Ash.create!(Organization, %{name: "Nspark Demo", slug: "nspark-demo"})
  end

t = [tenant: org.id, authorize?: false]

case Graph |> filter(name == "Refund & Dispute Agent") |> Ash.read!(t) do
  [g | _] ->
    IO.puts("Refund agent graph already exists (#{g.id}). Delete it to reseed.")

  [] ->
    project =
      case Project |> filter(name == "Northwind Pay") |> Ash.read!(t) do
        [p | _] -> p
        [] -> Ash.create!(Project, %{name: "Northwind Pay", status: :active}, t)
      end

    graph = Ash.create!(Graph, %{name: "Refund & Dispute Agent", project_id: project.id}, t)

    node = fn type, label, content, x, y ->
      Ash.create!(
        Node,
        %{
          type: type,
          label: label,
          content: content,
          graph_id: graph.id,
          metadata: %{"position" => %{"x" => x, "y" => y}}
        },
        t
      )
    end

    # ── consumer spine (left column) ─────────────────────────────────────────
    persona =
      node.(
        :persona,
        "Aria — Refund Specialist",
        """
        You are Aria, a senior refund and dispute specialist at Northwind Pay, a
        regulated payments company. You are calm, empathetic, and precise. You
        advocate for the customer while strictly following policy and law. You
        never speculate — if information is missing, you say so and use a tool to
        retrieve it before deciding.
        """,
        200,
        40
      )

    pii_guard =
      node.(
        :constraint,
        "PII & Card-Data Guardrail",
        """
        Never display a full card number, CVV, or bank account number. Refer to a
        card only by its last four digits ({payment_method_last4}). Do not repeat
        full PII in your reasoning or notes.
        """,
        200,
        210
      )

    authority =
      node.(
        :constraint,
        "Authority Limits",
        """
        You may auto-approve a refund up to $500 for an account in good standing
        ({account_flag} = clear). Refunds above $500, or for a flagged account,
        must be escalated — never approved by you directly.
        """,
        200,
        380
      )

    disclosure =
      node.(
        :constraint,
        "Regulatory Disclosure",
        """
        Before closing, state the legally required refund-processing window for
        {jurisdiction}: EU 14 days, US 7 business days, UK 14 days. If the
        jurisdiction is unknown, ask rather than guess.
        """,
        200,
        550
      )

    fraud_gate =
      node.(
        :conditional,
        "Fraud-Risk Gate",
        "{fraud_score} > 0.8",
        200,
        720
      )

    # branch target (only reached when the gate fires) — its variables are
    # conditionally required, so the contract should mark them optional.
    escalation =
      node.(
        :constraint,
        "Escalation Path",
        """
        Open a priority case in {escalation_queue} and summarize {fraud_signals}
        for the risk team. Do NOT issue a refund. Tell the customer their case is
        under review with a {sla_hours}-hour response SLA.
        """,
        520,
        720
      )

    tools =
      node.(
        :tool,
        "Support Tools",
        """
        Tools: lookup_transaction(order_id), issue_refund(order_id, amount),
        create_escalation(queue, summary). Always call lookup_transaction before
        any decision.
        """,
        200,
        890
      )

    evaluation =
      node.(
        :evaluation,
        "Pre-Response Self-Check",
        """
        Before responding, verify: (1) no full card/PII is present, (2) the
        decision is within your authority, (3) the regulatory window was stated,
        (4) tone is empathetic and clear. Fix any failing check before you reply.
        """,
        200,
        1060
      )

    output =
      node.(
        :output,
        "Output Schema",
        """
        Return ONLY JSON:
        {
          "decision": "refund_approved" | "refund_denied" | "escalated",
          "amount": number | null,
          "customer_message": string,
          "internal_notes": string,
          "disclosures": string[]
        }
        """,
        200,
        1230
      )

    # ── provider column (right) — runtime context & memory ───────────────────
    customer_ctx =
      node.(
        :context,
        "Customer Profile",
        "Customer {customer_name} · tier {account_tier} · {account_age_days} days old · standing {account_flag}.",
        620,
        120
      )

    transaction_ctx =
      node.(
        :context,
        "Disputed Transaction",
        "Order {order_id} for {order_amount} on {order_date}, card ending {payment_method_last4}. Reason: {dispute_reason}.",
        620,
        300
      )

    policy_window =
      node.(
        :context,
        "Eligibility Window",
        "Refund window for this category: {refund_window_days} days.",
        620,
        480
      )

    memory =
      node.(
        :memory,
        "Prior Interactions",
        "Recent history: {prior_tickets}. Do not contradict prior commitments.",
        620,
        660
      )

    dep = fn src, tgt ->
      Ash.create!(Edge, %{graph_id: graph.id, source_node_id: src.id, target_node_id: tgt.id}, t)
    end

    branch = fn src, tgt, which ->
      Ash.create!(
        Edge,
        %{
          graph_id: graph.id,
          source_node_id: src.id,
          target_node_id: tgt.id,
          metadata: %{"branch" => which}
        },
        t
      )
    end

    # consumer spine
    dep.(persona, pii_guard)
    dep.(pii_guard, authority)
    dep.(authority, disclosure)
    dep.(disclosure, fraud_gate)
    branch.(fraud_gate, escalation, "yes")
    dep.(fraud_gate, tools)
    dep.(tools, evaluation)
    dep.(evaluation, output)

    # providers feed consumers (so nothing floats)
    dep.(customer_ctx, persona)
    dep.(transaction_ctx, pii_guard)
    dep.(policy_window, fraud_gate)
    dep.(memory, persona)

    IO.puts("Created 'Refund & Dispute Agent' graph #{graph.id} — 13 nodes / 12 edges.")
end

IO.puts("Open /studio  (org=#{org.slug}, project=Northwind Pay)")
