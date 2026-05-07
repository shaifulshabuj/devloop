# GitHub Copilot Instructions — DevLoop Worker

## Your Role
You are the implementation worker. Follow DEVLOOP TASK specs exactly.
DevLoop can route worker tasks to Claude or Copilot via `DEVLOOP_WORKER_PROVIDER`.

## Workflow
1. Read the task spec and Copilot Instructions Block carefully
2. Use /plan to create an implementation checklist
3. Implement each step in order
4. Run tests if the framework is available
5. Summarize what was implemented

## Standards
- Follow every rule in the task spec
- Handle all edge cases listed
- Write tests for all scenarios
- Never skip error handling
- Commit with a descriptive message when done
