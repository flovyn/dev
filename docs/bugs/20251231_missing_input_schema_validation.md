# Bug: Missing Input Schema Validation on Workflow Trigger

**Date**: 2025-12-31
**Severity**: Medium
**Component**: REST API - Workflow Trigger
**Status**: Open

## Summary

When triggering a workflow via the REST API, the server does not validate the input against the workflow definition's `input_schema`. Invalid inputs are accepted and only fail later when the SDK worker attempts to deserialize them, resulting in confusing error messages.

## Reproduction

1. Trigger the data-pipeline-dag workflow with invalid input:

```bash
curl -X POST http://localhost:3000/api/orgs/dev/workflow-executions \
  -H 'Content-Type: application/json' \
  -d '{
    "kind": "data-pipeline-dag",
    "queue": "data-pipeline",
    "input": {
      "data_format": null,
      "pipeline_id": "example-pipeline_id",
      "data_source_url": "example-data_source_url",
      "transformations": [],
      "output_destination": "example-output_destination"
    }
  }'
```

2. Workflow is accepted (returns 201 Created)
3. Worker picks up workflow and immediately fails with:
   ```
   Serialization error: invalid type: null, expected string or map
   ```

## Expected Behavior

The server should reject the workflow trigger request with a 400 Bad Request and a clear validation error:

```json
{
  "error": "Input validation failed",
  "details": [
    {
      "path": "/data_format",
      "message": "null is not valid under any of the given schemas"
    }
  ]
}
```

## Root Cause

The workflow definition has an `input_schema` stored in the database:

```json
{
  "type": "object",
  "required": ["pipeline_id", "data_source_url", "data_format", "transformations", "output_destination"],
  "properties": {
    "data_format": {"$ref": "#/$defs/DataFormat"}
  },
  "$defs": {
    "DataFormat": {
      "enum": ["csv", "json", "parquet", "avro"],
      "type": "string"
    }
  }
}
```

However, the `trigger_workflow` handler in `flovyn-server/server/src/api/rest/workflows.rs` does not:
1. Look up the workflow definition by kind
2. Validate the input against the `input_schema` if one exists

## Impact

- Users get confusing error messages ("Serialization error") instead of clear validation errors
- Workflows are created and dispatched unnecessarily before failing
- Creates noise in the workflow execution history with immediately failed workflows
- Poor developer experience when integrating with Flovyn

## Proposed Solution

1. Add `jsonschema` crate dependency for JSON Schema validation
2. In `trigger_workflow`:
   - Look up workflow definition by `(org_id, kind)`
   - If `input_schema` is present, validate input against it
   - Return 400 with detailed validation errors if validation fails
3. Consider caching workflow definitions to avoid per-request lookups

## Files to Modify

- `flovyn-server/server/Cargo.toml` - Add jsonschema dependency
- `flovyn-server/server/src/api/rest/workflows.rs` - Add validation in `trigger_workflow`
- `flovyn-server/server/src/repository/workflow_definition_repository.rs` - Add `find_by_kind` method if not exists

## Database Evidence

```sql
-- Workflow definition has input_schema
SELECT input_schema FROM workflow_definition WHERE kind = 'data-pipeline-dag';

-- Workflow was accepted with invalid input
SELECT convert_from(input, 'UTF8') FROM workflow_execution
WHERE id = 'c4b12c28-8369-47f1-bbdb-6b081b3a6213';
-- Returns: {"data_format":null,...}

-- Workflow failed immediately
SELECT status, error FROM workflow_execution
WHERE id = 'c4b12c28-8369-47f1-bbdb-6b081b3a6213';
-- Returns: FAILED | Serialization error: invalid type: null, expected string or map
```
