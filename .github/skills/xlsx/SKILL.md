---
name: xlsx
description: "Use this skill any time a spreadsheet file is the primary input or output. This means any task where the user wants to: open, read, edit, or fix an existing .xlsx, .xlsm, .csv, or .tsv file (e.g., adding columns, computing formulas, formatting, charting, cleaning messy data); create a new spreadsheet from scratch or from other data sources; or convert between tabular file formats. Trigger especially when the user references a spreadsheet file by name or path — even casually (like \"the xlsx in my downloads\") — and wants something done to it or produced from it. Also trigger for cleaning or restructuring messy tabular data files (malformed rows, misplaced headers, junk data) into proper spreadsheets. The deliverable must be a spreadsheet file. Do NOT trigger when the primary deliverable is a Word document, HTML report, standalone Python script, database pipeline, or Google Sheets API integration, even if tabular data is involved."
license: Proprietary. LICENSE.txt has complete terms
---

# XLSX creation, editing, and analysis

## Overview

A user may ask you to create, edit, or analyze the contents of an .xlsx file.

**LibreOffice Required for Formula Recalculation**: Use `scripts/recalc.py` to recalculate formula values after creating/modifying files with openpyxl.

## Reading and Analyzing Data

### Data analysis with pandas
```python
import pandas as pd

# Read Excel
df = pd.read_excel('file.xlsx')                            # Default: first sheet
all_sheets = pd.read_excel('file.xlsx', sheet_name=None)   # All sheets as dict

# Analyze
df.head()       # Preview data
df.info()       # Column info
df.describe()   # Statistics

# Write Excel
df.to_excel('output.xlsx', index=False)
```

## CRITICAL: Use Formulas, Not Hardcoded Values

**Always use Excel formulas instead of calculating values in Python and hardcoding them.**

```python
# ❌ WRONG — hardcoding calculated values
total = df['Sales'].sum()
sheet['B10'] = total          # Bad: hardcodes 5000
sheet['C5'] = growth_rate     # Bad: hardcodes 0.15

# ✅ CORRECT — use Excel formulas
sheet['B10'] = '=SUM(B2:B9)'
sheet['C5'] = '=(C4-C2)/C2'
sheet['D20'] = '=AVERAGE(D2:D19)'
```

## Common Workflow

1. **Choose tool**: pandas for data analysis, openpyxl for formulas/formatting
2. **Create/Load**: Create new workbook or load existing file
3. **Modify**: Add/edit data, formulas, and formatting
4. **Save**: Write to file
5. **Recalculate formulas (MANDATORY IF USING FORMULAS)**:
   ```bash
   python scripts/recalc.py output.xlsx
   ```
6. **Verify and fix any errors** — the script returns JSON with error details

### Creating New Excel Files

```python
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment

wb = Workbook()
sheet = wb.active

# Add data
sheet['A1'] = 'Hello'
sheet['B1'] = 'World'
sheet.append(['Row', 'of', 'data'])

# Add formula
sheet['B2'] = '=SUM(A1:A10)'

# Formatting
sheet['A1'].font = Font(bold=True, color='FF0000')
sheet['A1'].fill = PatternFill('solid', start_color='FFFF00')
sheet['A1'].alignment = Alignment(horizontal='center')

# Column width
sheet.column_dimensions['A'].width = 20

wb.save('output.xlsx')
```

### Editing Existing Excel Files

```python
from openpyxl import load_workbook

wb = load_workbook('existing.xlsx')
sheet = wb.active  # or wb['SheetName']

# Modify cells
sheet['A1'] = 'New Value'
sheet.insert_rows(2)   # Insert row at position 2
sheet.delete_cols(3)   # Delete column 3

# Add new sheet
new_sheet = wb.create_sheet('NewSheet')
new_sheet['A1'] = 'Data'

wb.save('modified.xlsx')
```

## Recalculating Formulas

Excel files created/modified by openpyxl contain formulas as strings but not calculated values.

```bash
python scripts/recalc.py output.xlsx
python scripts/recalc.py output.xlsx 30  # with 30s timeout
```

The script returns JSON:
```json
{
  "status": "success",
  "total_errors": 0,
  "total_formulas": 42,
  "error_summary": {
    "#REF!": { "count": 2, "locations": ["Sheet1!B5", "Sheet1!C10"] }
  }
}
```

Fix identified errors, then recalculate again.

## Formula Verification Checklist

- [ ] **Test 2-3 sample references** before building full model
- [ ] **Column mapping**: confirm Excel columns match (column 64 = BL, not BK)
- [ ] **Row offset**: Excel rows are 1-indexed (DataFrame row 5 = Excel row 6)
- [ ] **NaN handling**: check for null values with `pd.notna()`
- [ ] **Division by zero**: check denominators before `/` in formulas
- [ ] **Wrong references**: verify all cell references point to intended cells
- [ ] **Cross-sheet references**: use correct format `Sheet1!A1`

## Best Practices

### Library Selection
- **pandas**: Best for data analysis, bulk operations, and simple data export
- **openpyxl**: Best for complex formatting, formulas, and Excel-specific features

### Working with openpyxl
- Cell indices are 1-based (row=1, column=1 = cell A1)
- Use `data_only=True` to read calculated values: `load_workbook('file.xlsx', data_only=True)`
- **Warning**: If saved with `data_only=True`, formulas are permanently lost
- Formulas are preserved but not evaluated — use `scripts/recalc.py` to update values

### Working with pandas
- Specify data types: `pd.read_excel('file.xlsx', dtype={'id': str})`
- Read specific columns: `pd.read_excel('file.xlsx', usecols=['A', 'C', 'E'])`
- Handle dates: `pd.read_excel('file.xlsx', parse_dates=['date_column'])`

## Code Style Guidelines

- Write minimal, concise Python code without unnecessary comments
- Avoid verbose variable names and redundant operations
- For Excel files themselves: add comments to cells with complex formulas

---

# Requirements for Outputs

## All Excel Files

- Use a consistent, professional font (e.g., Arial) unless instructed otherwise
- Every Excel model MUST be delivered with ZERO formula errors (#REF!, #DIV/0!, #VALUE!, #N/A, #NAME?)
- When modifying templates: EXACTLY match existing format, style, and conventions

## Financial Models

### Color Coding Standards (Industry-Standard)
- **Blue text (RGB: 0,0,255)**: Hardcoded inputs / numbers users will change
- **Black text (RGB: 0,0,0)**: ALL formulas and calculations
- **Green text (RGB: 0,128,0)**: Links from other worksheets within same workbook
- **Red text (RGB: 255,0,0)**: External links to other files
- **Yellow background (RGB: 255,255,0)**: Key assumptions needing attention

### Number Formatting
- **Years**: Format as text strings (e.g., "2024" not "2,024")
- **Currency**: Use `$#,##0`; ALWAYS specify units in headers ("Revenue ($mm)")
- **Zeros**: Use `$#,##0;($#,##0);-` to show zeros as "-"
- **Percentages**: Default to `0.0%` (one decimal)
- **Multiples**: Format as `0.0x` for valuation multiples (EV/EBITDA, P/E)
- **Negative numbers**: Use parentheses (123) not minus -123

### Formula Construction Rules
- Place ALL assumptions in separate assumption cells; use cell references, not hardcoded values
- Verify all cell references; check for off-by-one errors in ranges
- Ensure consistent formulas across all projection periods
- Document hardcoded values: "Source: Company 10-K, FY2024, Page 45"
