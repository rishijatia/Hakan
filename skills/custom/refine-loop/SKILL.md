---
name: refine-loop
description: "Iterative quality improvement loop: Generate → Review → Revise with file-based handoffs and optional human gate. Use for writing, code review, research synthesis, or any quality-sensitive output."
triggers:
  - "refine"
  - "improve iteratively"
  - "quality loop"
  - "draft and review"
  - "generate review revise"
related_skills:
  - subagent-driven-development
  - requesting-code-review
---

# Refine Loop — Iterative Quality Improvement

## When to Use
- Writing tasks that need review (articles, emails, docs, proposals)
- Code that should be reviewed before delivery
- Research synthesis that needs quality checks
- Any task where quality matters more than speed

## How It Works
1. **Generate:** Worker produces initial draft → saves to workspace/_draft.md
2. **Review:** Reviewer checks draft → writes structured review to workspace/_review.md
3. **Decide:** Parent reads review STATUS line
   - PASS → deliver to user
   - REVISE → loop back to step 1 with review context
4. **Human Gate (optional):** Ask user to approve before finalizing
5. **Max 3 iterations** then deliver best version with a warning

## Execution Flow

### Step 1: Generate
```python
delegate_task(
  goal="Write [TASK_DESCRIPTION]. Save output to /opt/data/workspace/_draft.md. Write ONLY the content, no preamble.",
  role="leaf",
  toolsets=["file", "terminal"]
)
```

### Step 2: Review
```python
delegate_task(
  goal="""Review the file at /opt/data/workspace/_draft.md for quality, accuracy, and completeness.
  Save your review to /opt/data/workspace/_review.md.
  Format the review as:
  - List of issues found (or 'No issues found')
  - Specific fixes needed
  - Final line: STATUS: PASS (if good enough) or STATUS: REVISE (if changes needed)

  IMPORTANT REVIEW GUIDELINES:
  - Only flag issues that are within the original task's scope. Do NOT demand
    information the task didn't ask for (pricing, legal, availability, etc.).
  - Evaluate on: clarity, accuracy, coherence, and fulfillment of the request.
  - Minor stylistic preferences are NOT grounds for REVISE.
  - Default to PASS if the work meets the task requirements. Be pragmatic, not
    perfectionist. The goal is "good and done," not "perfect and stuck in a loop."
  - If this is a second or third revision, only flag NEW issues not previously
    raised. Do not re-raise issues the writer already addressed.""",
  role="leaf",
  toolsets=["file"]
)
```

### Step 3: Read Status
Use read_file to check /opt/data/workspace/_review.md for the STATUS line.
- If "STATUS: PASS" → proceed to Step 4
- If "STATUS: REVISE" → go back to Step 1 with updated goal:
  "Revise /opt/data/workspace/_draft.md based on the review in /opt/data/workspace/_review.md. Save revised version to /opt/data/workspace/_draft.md."
- On iteration 2+, include the iteration number in the review goal so the
  reviewer knows to be more lenient: "This is iteration N — be pragmatic."

### Step 4: Human Gate (optional)
```python
clarify(message="Review complete. Here's the summary: [SUMMARY]. What would you like to do?",
        choices=["Send as-is", "Make more concise", "Add more detail", "Start over"])
```

### Step 5: Deliver
Read final draft from /opt/data/workspace/_draft.md and present to user.

## Cost Safeguards
- Max 3 iterations (configurable)
- After 3 iterations, deliver with note: "Reached max iterations. Here's the best version."
- Use mimo-v2.5-pro for the parent loop (cheap)
- Use claude-sonnet-4 for workers (quality)
- See `references/delegation-config-setup.md` for delegation config and cost details

## File Cleanup
After delivering to user, clean up temp files:
- /opt/data/workspace/_draft.md
- /opt/data/workspace/_review.md

## Pitfalls
- Don't pass full text in delegation goal strings. Use files. Always.
- Don't let refinement loops run unbounded. Hard cap at 3 iterations.
- Don't trust sub-agent output blindly. Always validate STATUS/PASS markers.
- Sub-agents can't see your conversation. Everything they need must be in the goal string or in a file they can access.
- After 3 iterations, the parent's context might get compressed, losing earlier iteration results. Files solve this.
- **Reviewer scope creep is common.** Reviewer agents tend to be overly strict — they'll flag pricing, availability, privacy info, etc. even for a simple product description. Mitigate by: (1) stating the output type and constraints explicitly in the reviewer goal ("this is a 150-word product description, not a spec doc"), (2) telling the reviewer what's out of scope ("do NOT flag missing pricing or availability"), (3) on iteration 2+, scoping the reviewer to only check the specific changes made, not re-reviewing everything.
- **3 iterations is the norm, not the exception.** Budget for it. The first draft is rarely good enough, and the first review is usually too strict.
- **delegate_task result `model` field shows the PARENT model**, not the child model. Don't be confused by this — the child actually uses the `delegation.model` from config. Verify by checking the child's behavior (token count, quality) rather than the reported model string.
- **Clean up temp files after delivery.** The _draft.md and _review.md files persist. Delete them after presenting the final result to avoid workspace clutter.
- **Reviewer too strict:** Without explicit guidelines, reviewers default to perfectionism and loop forever. Always include the review calibration guidelines in the review goal.
