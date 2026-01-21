# Design Document: FQL Editor Frontend Component

## Overview

A rich query editor component for Next.js that provides two modes:
1. **Visual Mode** - Form-based query builder for simple cases (default for new users)
2. **Text Mode** - FQL editor with syntax highlighting and autocomplete (power users)

Both modes stay in sync - changes in one reflect in the other.

## Goals

1. **Dual Mode** - Visual builder for beginners, text editor for power users
2. **Syntax Highlighting** - Color-code keywords, operators, fields, values, and strings
3. **Autocomplete** - Suggest fields, operators, values, and saved queries
4. **Validation** - Real-time error highlighting with helpful messages
5. **Keyboard-friendly** - Full keyboard navigation and shortcuts
6. **Responsive** - Works on desktop and mobile
7. **Bidirectional Sync** - Visual and text modes stay synchronized

## Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FQLEditor                                │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  [Visual Builder]  [Text Editor]          [Saved ▼]     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ╔═══════════════════════════════════════════════════════════╗  │
│  ║                   VISUAL BUILDER MODE                     ║  │
│  ╠═══════════════════════════════════════════════════════════╣  │
│  ║  ┌─────────┐ ┌─────┐ ┌───────────┐                       ║  │
│  ║  │status  ▼│ │ =  ▼│ │ FAILED  ▼ │  [×]                  ║  │
│  ║  └─────────┘ └─────┘ └───────────┘                       ║  │
│  ║                                           [AND ▼]        ║  │
│  ║  ┌───────────────┐ ┌─────┐ ┌───────────┐                 ║  │
│  ║  │metadata.env ▼ │ │ =  ▼│ │ prod    ▼ │  [×]            ║  │
│  ║  └───────────────┘ └─────┘ └───────────┘                 ║  │
│  ║                                           [AND ▼]        ║  │
│  ║  ┌───────────┐ ┌─────┐ ┌───────────┐                     ║  │
│  ║  │createdAt ▼│ │ >= ▼│ │ -7d       │  [×]                ║  │
│  ║  └───────────┘ └─────┘ └───────────┘                     ║  │
│  ║                                                          ║  │
│  ║  [+ Add Filter]                                          ║  │
│  ╚═══════════════════════════════════════════════════════════╝  │
│                                                                 │
│  ═══════════════════════ OR ════════════════════════════════    │
│                                                                 │
│  ╔═══════════════════════════════════════════════════════════╗  │
│  ║                    TEXT EDITOR MODE                       ║  │
│  ╠═══════════════════════════════════════════════════════════╣  │
│  ║  status = "FAILED" AND metadata.env = "prod" AND          ║  │
│  ║  createdAt >= -7d                                         ║  │
│  ║  ~~~~~~   ~~~~~~~~     ~~~~~~~~~~~~   ~~~~~~              ║  │
│  ║  keyword  string       field          string              ║  │
│  ╚═══════════════════════════════════════════════════════════╝  │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  ⚠ Validation message (if any)                           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Save Query...   │  │     Execute      │                    │
│  └──────────────────┘  └──────────────────┘                    │
└─────────────────────────────────────────────────────────────────┘
```

## Visual Query Builder

### Design Principles

1. **Progressive Disclosure** - Start simple, reveal complexity as needed
2. **Smart Defaults** - Pre-select common operators and suggest popular fields
3. **Immediate Feedback** - Show FQL preview as user builds query
4. **Graceful Degradation** - Complex queries can only be edited in text mode

### Builder Data Model

```typescript
interface QueryBuilderState {
  conditions: ConditionGroup;
  orderBy?: OrderByClause;
}

interface ConditionGroup {
  logic: 'AND' | 'OR';
  conditions: (Condition | ConditionGroup)[];
}

interface Condition {
  id: string;  // For React keys and drag-drop
  field: string;
  operator: Operator;
  value: ConditionValue;
}

type Operator =
  | 'eq' | 'neq'           // = !=
  | 'gt' | 'gte'           // > >=
  | 'lt' | 'lte'           // < <=
  | 'contains'             // ~
  | 'notContains'          // !~
  | 'in' | 'notIn'         // IN, NOT IN
  | 'isNull' | 'isNotNull';

type ConditionValue =
  | { type: 'string'; value: string }
  | { type: 'number'; value: number }
  | { type: 'boolean'; value: boolean }
  | { type: 'list'; values: string[] }
  | { type: 'relativeTime'; value: string }  // -7d, -24h
  | { type: 'function'; name: string };      // NOW(), TODAY()

interface OrderByClause {
  field: string;
  direction: 'ASC' | 'DESC';
}
```

### Visual Builder Components

```tsx
// Main builder component
function QueryBuilder({
  state,
  onChange,
  fields,
  metadataFields,
}: QueryBuilderProps) {
  return (
    <div className="space-y-3">
      <ConditionGroupEditor
        group={state.conditions}
        onChange={(conditions) => onChange({ ...state, conditions })}
        fields={fields}
        metadataFields={metadataFields}
        isRoot
      />

      <OrderByEditor
        value={state.orderBy}
        onChange={(orderBy) => onChange({ ...state, orderBy })}
        fields={fields}
      />
    </div>
  );
}

// Single condition row
function ConditionRow({
  condition,
  onChange,
  onRemove,
  fields,
  metadataFields,
}: ConditionRowProps) {
  const selectedField = useMemo(() =>
    [...fields, ...metadataFields].find(f => f.name === condition.field),
    [condition.field, fields, metadataFields]
  );

  const availableOperators = useMemo(() =>
    getOperatorsForFieldType(selectedField?.type),
    [selectedField]
  );

  return (
    <div className="flex items-center gap-2">
      {/* Field selector */}
      <FieldSelect
        value={condition.field}
        onChange={(field) => onChange({
          ...condition,
          field,
          operator: 'eq',  // Reset operator
          value: { type: 'string', value: '' },  // Reset value
        })}
        fields={fields}
        metadataFields={metadataFields}
      />

      {/* Operator selector */}
      <OperatorSelect
        value={condition.operator}
        onChange={(operator) => onChange({ ...condition, operator })}
        operators={availableOperators}
      />

      {/* Value input - dynamic based on field type */}
      <ValueInput
        field={selectedField}
        operator={condition.operator}
        value={condition.value}
        onChange={(value) => onChange({ ...condition, value })}
      />

      {/* Remove button */}
      <Button variant="ghost" size="icon" onClick={onRemove}>
        <XIcon className="h-4 w-4" />
      </Button>
    </div>
  );
}
```

### Field Selector with Grouping

```tsx
function FieldSelect({ value, onChange, fields, metadataFields }: FieldSelectProps) {
  return (
    <Select value={value} onValueChange={onChange}>
      <SelectTrigger className="w-48">
        <SelectValue placeholder="Select field..." />
      </SelectTrigger>
      <SelectContent>
        {/* Standard fields */}
        <SelectGroup>
          <SelectLabel>Fields</SelectLabel>
          {fields.map(field => (
            <SelectItem key={field.name} value={field.name}>
              <div className="flex items-center gap-2">
                <FieldTypeIcon type={field.type} />
                <span>{field.displayName}</span>
              </div>
            </SelectItem>
          ))}
        </SelectGroup>

        {/* Metadata fields from registry */}
        {metadataFields.length > 0 && (
          <SelectGroup>
            <SelectLabel>Metadata</SelectLabel>
            {metadataFields.map(field => (
              <SelectItem key={field.name} value={`metadata.${field.name}`}>
                <div className="flex items-center gap-2">
                  <TagIcon className="h-4 w-4 text-purple-500" />
                  <span>{field.displayName}</span>
                </div>
              </SelectItem>
            ))}
          </SelectGroup>
        )}

        {/* Option to add custom metadata field */}
        <SelectGroup>
          <SelectItem value="__custom_metadata__">
            <div className="flex items-center gap-2 text-gray-500">
              <PlusIcon className="h-4 w-4" />
              <span>Custom metadata field...</span>
            </div>
          </SelectItem>
        </SelectGroup>
      </SelectContent>
    </Select>
  );
}
```

### Value Input Variants

```tsx
function ValueInput({ field, operator, value, onChange }: ValueInputProps) {
  // Null operators don't need value input
  if (operator === 'isNull' || operator === 'isNotNull') {
    return null;
  }

  // IN/NOT IN operators need multi-select or tag input
  if (operator === 'in' || operator === 'notIn') {
    return (
      <MultiValueInput
        values={value.type === 'list' ? value.values : []}
        onChange={(values) => onChange({ type: 'list', values })}
        suggestions={field?.type === 'enum' ? field.values : undefined}
      />
    );
  }

  // Enum fields get dropdown
  if (field?.type === 'enum' && field.values) {
    return (
      <Select
        value={value.type === 'string' ? value.value : ''}
        onValueChange={(v) => onChange({ type: 'string', value: v })}
      >
        <SelectTrigger className="w-40">
          <SelectValue placeholder="Select..." />
        </SelectTrigger>
        <SelectContent>
          {field.values.map(v => (
            <SelectItem key={v} value={v}>{v}</SelectItem>
          ))}
        </SelectContent>
      </Select>
    );
  }

  // DateTime fields get special input with presets
  if (field?.type === 'datetime') {
    return (
      <DateTimeInput
        value={value}
        onChange={onChange}
        presets={[
          { label: 'Last hour', value: '-1h' },
          { label: 'Last 24 hours', value: '-24h' },
          { label: 'Last 7 days', value: '-7d' },
          { label: 'Last 30 days', value: '-30d' },
          { label: 'Custom date...', value: '__custom__' },
        ]}
      />
    );
  }

  // Boolean fields get toggle
  if (field?.type === 'boolean') {
    return (
      <Select
        value={value.type === 'boolean' ? String(value.value) : ''}
        onValueChange={(v) => onChange({ type: 'boolean', value: v === 'true' })}
      >
        <SelectTrigger className="w-24">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="true">true</SelectItem>
          <SelectItem value="false">false</SelectItem>
        </SelectContent>
      </Select>
    );
  }

  // Number fields get number input
  if (field?.type === 'number') {
    return (
      <Input
        type="number"
        value={value.type === 'number' ? value.value : ''}
        onChange={(e) => onChange({ type: 'number', value: parseFloat(e.target.value) })}
        className="w-32"
      />
    );
  }

  // Default: text input
  return (
    <Input
      type="text"
      value={value.type === 'string' ? value.value : ''}
      onChange={(e) => onChange({ type: 'string', value: e.target.value })}
      placeholder="Enter value..."
      className="w-40"
    />
  );
}
```

### Nested Groups (Advanced)

```tsx
function ConditionGroupEditor({
  group,
  onChange,
  fields,
  metadataFields,
  isRoot = false,
  onRemove,
}: ConditionGroupEditorProps) {
  const addCondition = () => {
    onChange({
      ...group,
      conditions: [
        ...group.conditions,
        {
          id: crypto.randomUUID(),
          field: '',
          operator: 'eq',
          value: { type: 'string', value: '' },
        },
      ],
    });
  };

  const addGroup = () => {
    onChange({
      ...group,
      conditions: [
        ...group.conditions,
        {
          logic: 'AND',
          conditions: [],
        },
      ],
    });
  };

  return (
    <div className={cn(
      "space-y-2",
      !isRoot && "ml-4 pl-4 border-l-2 border-gray-200"
    )}>
      {group.conditions.map((condition, index) => (
        <div key={'id' in condition ? condition.id : index}>
          {/* Logic operator between conditions */}
          {index > 0 && (
            <Select
              value={group.logic}
              onValueChange={(logic) => onChange({ ...group, logic })}
            >
              <SelectTrigger className="w-20 my-2">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="AND">AND</SelectItem>
                <SelectItem value="OR">OR</SelectItem>
              </SelectContent>
            </Select>
          )}

          {'field' in condition ? (
            <ConditionRow
              condition={condition}
              onChange={(updated) => onChange({
                ...group,
                conditions: group.conditions.map((c, i) =>
                  i === index ? updated : c
                ),
              })}
              onRemove={() => onChange({
                ...group,
                conditions: group.conditions.filter((_, i) => i !== index),
              })}
              fields={fields}
              metadataFields={metadataFields}
            />
          ) : (
            <ConditionGroupEditor
              group={condition}
              onChange={(updated) => onChange({
                ...group,
                conditions: group.conditions.map((c, i) =>
                  i === index ? updated : c
                ),
              })}
              onRemove={() => onChange({
                ...group,
                conditions: group.conditions.filter((_, i) => i !== index),
              })}
              fields={fields}
              metadataFields={metadataFields}
            />
          )}
        </div>
      ))}

      {/* Add buttons */}
      <div className="flex gap-2 pt-2">
        <Button variant="outline" size="sm" onClick={addCondition}>
          <PlusIcon className="h-4 w-4 mr-1" />
          Add Filter
        </Button>
        <Button variant="ghost" size="sm" onClick={addGroup}>
          <BracesIcon className="h-4 w-4 mr-1" />
          Add Group
        </Button>
        {!isRoot && onRemove && (
          <Button variant="ghost" size="sm" onClick={onRemove}>
            <TrashIcon className="h-4 w-4 mr-1" />
            Remove Group
          </Button>
        )}
      </div>
    </div>
  );
}
```

### Bidirectional Sync

```typescript
// Convert builder state to FQL string
function builderToFQL(state: QueryBuilderState): string {
  const filter = conditionGroupToFQL(state.conditions);
  const orderBy = state.orderBy
    ? ` ORDER BY ${state.orderBy.field} ${state.orderBy.direction}`
    : '';
  return filter + orderBy;
}

function conditionGroupToFQL(group: ConditionGroup): string {
  if (group.conditions.length === 0) return '';

  const parts = group.conditions.map(c => {
    if ('field' in c) {
      return conditionToFQL(c);
    } else {
      return `(${conditionGroupToFQL(c)})`;
    }
  });

  return parts.join(` ${group.logic} `);
}

function conditionToFQL(condition: Condition): string {
  const { field, operator, value } = condition;

  switch (operator) {
    case 'eq':
      return `${field} = ${valueToFQL(value)}`;
    case 'neq':
      return `${field} != ${valueToFQL(value)}`;
    case 'gt':
      return `${field} > ${valueToFQL(value)}`;
    case 'in':
      return `${field} IN (${(value as ListValue).values.map(v => `"${v}"`).join(', ')})`;
    case 'isNull':
      return `${field} IS NULL`;
    // ... other operators
  }
}

// Parse FQL string to builder state (best effort)
function fqlToBuilder(fql: string): QueryBuilderState | null {
  try {
    const ast = parseFQL(fql);
    return astToBuilderState(ast);
  } catch {
    // Query too complex for visual builder
    return null;
  }
}

// Check if FQL can be represented in visual builder
function canRepresentInBuilder(fql: string): boolean {
  try {
    const ast = parseFQL(fql);
    return isBuilderCompatible(ast);
  } catch {
    return false;
  }
}
```

### Mode Switching UX

```tsx
function FQLEditor({ value, onChange, ...props }: FQLEditorProps) {
  const [mode, setMode] = useState<'visual' | 'text'>('visual');
  const [builderState, setBuilderState] = useState<QueryBuilderState | null>(null);

  // Parse FQL to builder state when switching to visual mode
  const handleModeChange = (newMode: 'visual' | 'text') => {
    if (newMode === 'visual') {
      const parsed = fqlToBuilder(value);
      if (parsed) {
        setBuilderState(parsed);
        setMode('visual');
      } else {
        // Show warning - query too complex
        toast({
          title: "Cannot switch to Visual Builder",
          description: "This query contains features not supported in visual mode. Please edit in text mode.",
          variant: "warning",
        });
      }
    } else {
      setMode('text');
    }
  };

  // Sync builder changes to FQL
  const handleBuilderChange = (state: QueryBuilderState) => {
    setBuilderState(state);
    onChange(builderToFQL(state));
  };

  // Sync text changes to builder (if possible)
  const handleTextChange = (fql: string) => {
    onChange(fql);
    const parsed = fqlToBuilder(fql);
    setBuilderState(parsed);  // null if can't parse
  };

  const canSwitchToVisual = builderState !== null || canRepresentInBuilder(value);

  return (
    <div>
      {/* Mode toggle */}
      <div className="flex border-b mb-4">
        <button
          className={cn(
            "px-4 py-2 font-medium",
            mode === 'visual' && "border-b-2 border-blue-500 text-blue-600"
          )}
          onClick={() => handleModeChange('visual')}
          disabled={!canSwitchToVisual}
          title={!canSwitchToVisual ? "Query too complex for visual builder" : undefined}
        >
          <FormInputIcon className="h-4 w-4 mr-2 inline" />
          Visual Builder
        </button>
        <button
          className={cn(
            "px-4 py-2 font-medium",
            mode === 'text' && "border-b-2 border-blue-500 text-blue-600"
          )}
          onClick={() => handleModeChange('text')}
        >
          <CodeIcon className="h-4 w-4 mr-2 inline" />
          Text Editor
        </button>
      </div>

      {/* Editor content */}
      {mode === 'visual' && builderState ? (
        <QueryBuilder
          state={builderState}
          onChange={handleBuilderChange}
          fields={props.fields}
          metadataFields={props.metadataFields}
        />
      ) : (
        <TextEditor
          value={value}
          onChange={handleTextChange}
          {...props}
        />
      )}

      {/* FQL preview in visual mode */}
      {mode === 'visual' && (
        <div className="mt-4 p-3 bg-gray-50 rounded-md font-mono text-sm">
          <span className="text-gray-500">FQL: </span>
          {value || <span className="text-gray-400">No filters applied</span>}
        </div>
      )}
    </div>
  );
}
```

### Feature Comparison

| Feature | Visual Builder | Text Editor |
|---------|---------------|-------------|
| Simple AND queries | Yes | Yes |
| Simple OR queries | Yes | Yes |
| Mixed AND/OR | Yes (with groups) | Yes |
| Nested parentheses | Limited (1 level) | Unlimited |
| All operators | Yes | Yes |
| Metadata fields | Yes | Yes |
| ORDER BY | Yes | Yes |
| Functions (NOW, TODAY) | Yes | Yes |
| Relative time (-7d) | Yes | Yes |
| Complex expressions | No | Yes |
| Syntax highlighting | Preview only | Full |
| Autocomplete | Dropdowns | Inline |

## Technology Choice

### Option A: CodeMirror 6 (Recommended)

**Pros:**
- Lightweight (~150KB gzipped)
- Excellent performance with large documents
- First-class TypeScript support
- Modular architecture
- Easy custom language support
- Active development

**Cons:**
- Learning curve for extension system
- Less "batteries included" than Monaco

### Option B: Monaco Editor

**Pros:**
- VS Code's editor, very feature-rich
- Built-in language services
- Great out-of-box experience

**Cons:**
- Heavy (~2MB)
- Overkill for simple query language
- Harder to customize deeply

**Decision:** CodeMirror 6 - lighter weight, sufficient for FQL, easier to customize.

## Component API

### FQLEditor Component

```tsx
interface FQLEditorProps {
  // Core
  value: string;
  onChange: (value: string) => void;
  entity: 'workflow' | 'task';

  // Optional
  placeholder?: string;
  disabled?: boolean;
  readOnly?: boolean;
  minHeight?: number;
  maxHeight?: number;

  // Validation
  onValidate?: (errors: ValidationError[]) => void;
  validateOnChange?: boolean;  // default: true (debounced)
  validateDebounceMs?: number; // default: 300

  // Autocomplete
  enableAutocomplete?: boolean; // default: true
  customFields?: FieldDefinition[]; // Additional fields from schema registry

  // Actions
  onExecute?: (query: string) => void; // Ctrl+Enter handler
  onSave?: (query: string) => void;    // Ctrl+S handler

  // Saved queries
  savedQueries?: SavedQuery[];
  onSelectSavedQuery?: (query: SavedQuery) => void;
}

interface ValidationError {
  line: number;
  column: number;
  endColumn: number;
  message: string;
  severity: 'error' | 'warning' | 'info';
}

interface FieldDefinition {
  name: string;
  displayName: string;
  type: 'string' | 'number' | 'boolean' | 'datetime' | 'enum';
  values?: string[]; // For enum types
  description?: string;
}

interface SavedQuery {
  id: string;
  name: string;
  query: string;
  description?: string;
}
```

### Usage Example

```tsx
import { FQLEditor } from '@flovyn/ui';
import { useMetadataFields, useSavedQueries, useQueryExecution } from '@flovyn/hooks';

function WorkflowQueryPage() {
  const [query, setQuery] = useState('');
  const { fields } = useMetadataFields('workflow');
  const { savedQueries } = useSavedQueries('workflow');
  const { execute, results, loading } = useQueryExecution();

  return (
    <div>
      <FQLEditor
        value={query}
        onChange={setQuery}
        entity="workflow"
        customFields={fields}
        savedQueries={savedQueries}
        onExecute={(q) => execute('workflow', q)}
        placeholder="status = &quot;FAILED&quot; AND createdAt >= -7d"
      />

      {loading && <Spinner />}
      {results && <ResultsTable data={results} />}
    </div>
  );
}
```

## Syntax Highlighting

### Token Types and Colors

```typescript
const fqlTheme = {
  keyword: '#7C3AED',      // AND, OR, NOT, ORDER BY, ASC, DESC, IN, IS
  operator: '#059669',     // =, !=, >, <, >=, <=, ~, !~
  field: '#2563EB',        // status, kind, createdAt, metadata.*
  string: '#D97706',       // "value", 'value'
  number: '#DC2626',       // 123, 45.6
  function: '#9333EA',     // NOW(), TODAY()
  relativeTime: '#0891B2', // -7d, -24h, -30m
  null: '#6B7280',         // NULL
  bracket: '#374151',      // (, )
  error: '#EF4444',        // Underline for errors
};
```

### Grammar Definition (CodeMirror)

```typescript
import { LRLanguage, LanguageSupport } from '@codemirror/language';
import { styleTags, tags } from '@lezer/highlight';

// Lezer grammar for FQL
const fqlGrammar = `
@top Query { expression? orderBy? }

expression {
  term (logicalOp term)*
}

term {
  comparison |
  "(" expression ")" |
  NotOp term
}

comparison {
  Field comparisonOp Value |
  Field nullOp
}

Field { Identifier | MetadataField }
MetadataField { "metadata" "." Identifier }

Value {
  String |
  Number |
  Boolean |
  List |
  RelativeTime |
  Function
}

List { "(" Value ("," Value)* ")" }

logicalOp { @specialize<Identifier, "AND" | "OR"> }
comparisonOp { "=" | "!=" | ">" | ">=" | "<" | "<=" | "~" | "!~" | InOp | NotInOp }
nullOp { IsNull | IsNotNull }

orderBy { OrderBy Field orderDirection? }
orderDirection { Asc | Desc }

@tokens {
  Identifier { $[a-zA-Z_] $[a-zA-Z0-9_]* }
  String { '"' (!["\\] | "\\" _)* '"' }
  Number { $[0-9]+ ("." $[0-9]+)? }
  Boolean { "true" | "false" }
  RelativeTime { "-" $[0-9]+ $[dhm] }
  Function { $[A-Z]+ "(" ")" }

  InOp { "IN" }
  NotInOp { "NOT" " "+ "IN" }
  NotOp { "NOT" }
  IsNull { "IS" " "+ "NULL" }
  IsNotNull { "IS" " "+ "NOT" " "+ "NULL" }
  OrderBy { "ORDER" " "+ "BY" }
  Asc { "ASC" }
  Desc { "DESC" }

  @precedence { InOp, NotInOp, NotOp, IsNull, IsNotNull, OrderBy, Asc, Desc, Identifier }
}
`;
```

## Autocomplete System

### Trigger Points

| Context | Trigger | Suggestions |
|---------|---------|-------------|
| Start of query | Type anything | Fields, saved queries |
| After field | Space | Operators |
| After operator | Space | Values (enum), functions |
| After `metadata.` | Type anything | Metadata fields from registry |
| After `IN (` | Type anything | Enum values |
| After `AND` / `OR` | Space | Fields |

### Autocomplete Provider

```typescript
import { CompletionContext, autocompletion } from '@codemirror/autocomplete';

interface AutocompleteConfig {
  entity: 'workflow' | 'task';
  metadataFields: FieldDefinition[];
  savedQueries: SavedQuery[];
  apiEndpoint: string;
}

function createFQLAutocomplete(config: AutocompleteConfig) {
  return autocompletion({
    override: [
      async (context: CompletionContext) => {
        const { state, pos } = context;
        const line = state.doc.lineAt(pos);
        const textBefore = line.text.slice(0, pos - line.from);

        // Determine context
        const completionContext = analyzeContext(textBefore);

        switch (completionContext.type) {
          case 'field':
            return fieldCompletions(config, completionContext);
          case 'operator':
            return operatorCompletions(completionContext);
          case 'value':
            return valueCompletions(config, completionContext);
          case 'metadata':
            return metadataFieldCompletions(config, completionContext);
          case 'savedQuery':
            return savedQueryCompletions(config, completionContext);
        }
      },
    ],
  });
}

function fieldCompletions(config: AutocompleteConfig, ctx: CompletionContext) {
  const baseFields = config.entity === 'workflow'
    ? workflowFields
    : taskFields;

  return {
    from: ctx.matchStart,
    options: [
      ...baseFields.map(f => ({
        label: f.name,
        type: 'property',
        detail: f.description,
        boost: f.common ? 1 : 0,
      })),
      {
        label: 'metadata.',
        type: 'property',
        detail: 'Access metadata fields',
      },
    ],
  };
}

function metadataFieldCompletions(config: AutocompleteConfig, ctx: CompletionContext) {
  return {
    from: ctx.matchStart,
    options: config.metadataFields.map(f => ({
      label: `metadata.${f.name}`,
      type: 'property',
      detail: f.displayName,
      info: f.description,
    })),
  };
}

function valueCompletions(config: AutocompleteConfig, ctx: CompletionContext) {
  const field = ctx.currentField;

  // Enum field - suggest allowed values
  if (field?.type === 'enum' && field.values) {
    return {
      from: ctx.matchStart,
      options: field.values.map(v => ({
        label: `"${v}"`,
        type: 'constant',
      })),
    };
  }

  // DateTime field - suggest functions and relative times
  if (field?.type === 'datetime') {
    return {
      from: ctx.matchStart,
      options: [
        { label: 'NOW()', type: 'function', detail: 'Current timestamp' },
        { label: 'TODAY()', type: 'function', detail: 'Start of today' },
        { label: '-1h', type: 'constant', detail: '1 hour ago' },
        { label: '-24h', type: 'constant', detail: '24 hours ago' },
        { label: '-7d', type: 'constant', detail: '7 days ago' },
        { label: '-30d', type: 'constant', detail: '30 days ago' },
      ],
    };
  }

  return null;
}
```

### Server-Side Autocomplete API

For dynamic suggestions (e.g., actual metadata values in use):

```
POST /api/tenants/{tenant}/query/autocomplete
```

Request:
```json
{
  "entity": "workflow",
  "query": "status = \"FAILED\" AND metadata.customerId = \"",
  "cursorPosition": 48,
  "context": "value",
  "field": "metadata.customerId"
}
```

Response:
```json
{
  "suggestions": [
    {"value": "CUST-001", "count": 156},
    {"value": "CUST-002", "count": 89},
    {"value": "CUST-003", "count": 45}
  ],
  "hasMore": true
}
```

## Real-Time Validation

### Client-Side Validation

Immediate feedback for syntax errors:

```typescript
import { linter, Diagnostic } from '@codemirror/lint';

const fqlLinter = linter((view) => {
  const diagnostics: Diagnostic[] = [];
  const text = view.state.doc.toString();

  try {
    const ast = parseFQL(text);
    validateAST(ast, diagnostics);
  } catch (e) {
    if (e instanceof ParseError) {
      diagnostics.push({
        from: e.position,
        to: e.position + e.length,
        severity: 'error',
        message: e.message,
      });
    }
  }

  return diagnostics;
});
```

### Server-Side Validation

Deep validation (field existence, value validity):

```typescript
// Debounced server validation
const useServerValidation = (query: string, entity: string) => {
  const [errors, setErrors] = useState<ValidationError[]>([]);

  useEffect(() => {
    const timer = setTimeout(async () => {
      if (!query.trim()) {
        setErrors([]);
        return;
      }

      const response = await fetch('/api/query/validate', {
        method: 'POST',
        body: JSON.stringify({ entity, query }),
      });

      const result = await response.json();
      setErrors(result.errors || []);
    }, 300);

    return () => clearTimeout(timer);
  }, [query, entity]);

  return errors;
};
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Enter` | Execute query |
| `Ctrl+S` | Save query |
| `Ctrl+Space` | Trigger autocomplete |
| `Escape` | Close autocomplete popup |
| `Tab` | Accept autocomplete suggestion |
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` | Redo |
| `Ctrl+/` | Toggle comment (if supported) |

## Saved Queries Dropdown

```tsx
interface SavedQueriesDropdownProps {
  queries: SavedQuery[];
  onSelect: (query: SavedQuery) => void;
  onEdit: (query: SavedQuery) => void;
  onDelete: (query: SavedQuery) => void;
}

function SavedQueriesDropdown({ queries, onSelect, onEdit, onDelete }: SavedQueriesDropdownProps) {
  const [search, setSearch] = useState('');
  const filtered = queries.filter(q =>
    q.name.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="outline">
          <BookmarkIcon /> Saved Queries
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80">
        <Input
          placeholder="Search queries..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <div className="mt-2 max-h-64 overflow-auto">
          {filtered.map(query => (
            <div
              key={query.id}
              className="flex items-center justify-between p-2 hover:bg-gray-100 rounded cursor-pointer"
              onClick={() => onSelect(query)}
            >
              <div>
                <div className="font-medium">{query.name}</div>
                <div className="text-sm text-gray-500 truncate max-w-48">
                  {query.query}
                </div>
              </div>
              <div className="flex gap-1">
                <Button size="icon" variant="ghost" onClick={(e) => {
                  e.stopPropagation();
                  onEdit(query);
                }}>
                  <PencilIcon />
                </Button>
                <Button size="icon" variant="ghost" onClick={(e) => {
                  e.stopPropagation();
                  onDelete(query);
                }}>
                  <TrashIcon />
                </Button>
              </div>
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}
```

## Mobile Considerations

On mobile devices:
- Larger touch targets for autocomplete items
- Simplified toolbar (icons only)
- Full-screen editor mode option
- Virtual keyboard aware positioning

```tsx
const isMobile = useMediaQuery('(max-width: 768px)');

<FQLEditor
  minHeight={isMobile ? 100 : 60}
  maxHeight={isMobile ? 200 : 400}
  toolbarPosition={isMobile ? 'bottom' : 'top'}
/>
```

## Package Structure

```
packages/fql-editor/
├── src/
│   ├── FQLEditor.tsx           # Main component
│   ├── components/
│   │   ├── EditorCore.tsx      # CodeMirror wrapper
│   │   ├── AutocompletePopup.tsx
│   │   ├── ValidationBar.tsx
│   │   ├── Toolbar.tsx
│   │   └── SavedQueriesDropdown.tsx
│   ├── language/
│   │   ├── grammar.ts          # Lezer grammar
│   │   ├── highlight.ts        # Syntax highlighting
│   │   └── autocomplete.ts     # Autocomplete provider
│   ├── validation/
│   │   ├── parser.ts           # FQL parser
│   │   ├── validator.ts        # AST validator
│   │   └── types.ts            # Validation types
│   ├── hooks/
│   │   ├── useServerValidation.ts
│   │   ├── useAutocomplete.ts
│   │   └── useSavedQueries.ts
│   ├── themes/
│   │   ├── light.ts
│   │   └── dark.ts
│   └── index.ts
├── package.json
└── tsconfig.json
```

## Dependencies

```json
{
  "dependencies": {
    "@codemirror/autocomplete": "^6.x",
    "@codemirror/commands": "^6.x",
    "@codemirror/language": "^6.x",
    "@codemirror/lint": "^6.x",
    "@codemirror/state": "^6.x",
    "@codemirror/view": "^6.x",
    "@lezer/generator": "^1.x",
    "@lezer/highlight": "^1.x",
    "react": "^18.x"
  },
  "peerDependencies": {
    "@radix-ui/react-popover": "^1.x"
  }
}
```

## Implementation Phases

### Phase 1: Core Editor
- [ ] Set up CodeMirror 6 with React wrapper
- [ ] Implement basic syntax highlighting
- [ ] Add keyboard shortcuts
- [ ] Create light/dark themes

### Phase 2: Autocomplete
- [ ] Implement field autocomplete
- [ ] Implement operator autocomplete
- [ ] Implement value autocomplete for enums
- [ ] Add metadata field suggestions from registry
- [ ] Add saved query suggestions

### Phase 3: Validation
- [ ] Client-side syntax validation
- [ ] Server-side deep validation
- [ ] Error highlighting with messages
- [ ] Validation bar component

### Phase 4: Saved Queries UI
- [ ] Saved queries dropdown
- [ ] Save query dialog
- [ ] Edit/delete functionality
- [ ] Query usage tracking display

### Phase 5: Polish
- [ ] Mobile responsiveness
- [ ] Accessibility (ARIA labels, keyboard navigation)
- [ ] Performance optimization
- [ ] Documentation and examples
