# PDF Forms Guide

**CRITICAL: You MUST complete these steps in order. Do not skip ahead to writing code.**

First, check if the PDF has fillable form fields by running:
`python scripts/check_fillable_fields <file.pdf>`

Then follow the appropriate section below.

---

# Fillable Fields

If the PDF has fillable form fields:

1. Run: `python scripts/extract_form_field_info.py <input.pdf> <field_info.json>`

   This creates a JSON with fields in this format:
   ```json
   [
     {
       "field_id": "last_name",
       "page": 1,
       "rect": [left, bottom, right, top],
       "type": "text"
     },
     {
       "field_id": "agree_checkbox",
       "type": "checkbox",
       "checked_value": "/On",
       "unchecked_value": "/Off"
     },
     {
       "field_id": "gender",
       "type": "radio_group",
       "radio_options": [{"value": "/Male", "rect": [...]}, {"value": "/Female", "rect": [...]}]
     },
     {
       "field_id": "country",
       "type": "choice",
       "choice_options": [{"value": "US", "text": "United States"}]
     }
   ]
   ```

2. Convert PDF to images: `python scripts/convert_pdf_to_images.py <file.pdf> <output_dir>`
   Analyze images to understand each field's purpose.

3. Create `field_values.json`:
   ```json
   [
     {"field_id": "last_name", "description": "User last name", "page": 1, "value": "Simpson"},
     {"field_id": "agree_checkbox", "description": "18+ checkbox", "page": 1, "value": "/On"}
   ]
   ```

4. Fill: `python scripts/fill_fillable_fields.py <input.pdf> <field_values.json> <output.pdf>`

---

# Non-fillable Fields

If the PDF doesn't have fillable form fields, add text annotations.

## Step 1: Try Structure Extraction

```bash
python scripts/extract_form_structure.py <input.pdf> form_structure.json
```

If `form_structure.json` has meaningful labels → use **Approach A**.
If PDF is scanned/image-based with no text labels → use **Approach B**.

## Approach A: Structure-Based Coordinates (Preferred)

### A.1: Analyze Structure
Read `form_structure.json` and identify label groups, row structure, field columns, and checkboxes.

Coordinate system: y=0 is at TOP of page, y increases downward.

### A.2: Create fields.json with PDF Coordinates

```json
{
  "pages": [{"page_number": 1, "pdf_width": 612, "pdf_height": 792}],
  "form_fields": [
    {
      "page_number": 1,
      "description": "Last name entry field",
      "field_label": "Last Name",
      "label_bounding_box": [43, 63, 87, 73],
      "entry_bounding_box": [92, 63, 260, 79],
      "entry_text": {"text": "Smith", "font_size": 10}
    }
  ]
}
```

Use `pdf_width`/`pdf_height` when using PDF coordinates from `form_structure.json`.

### A.3: Validate
```bash
python scripts/check_bounding_boxes.py fields.json
```

## Approach B: Visual Estimation (Fallback)

### B.1: Convert PDF to Images
```bash
python scripts/convert_pdf_to_images.py <input.pdf> <images_dir/>
```

### B.2: Identify Fields Visually
Examine page images to find form sections and approximate field locations.

### B.3: Zoom Refinement (CRITICAL for accuracy)
```bash
magick <page_image> -crop <width>x<height>+<x>+<y> +repage <crop_output.png>
```

Convert crop coordinates back to full image coordinates:
- full_x = crop_x + crop_offset_x
- full_y = crop_y + crop_offset_y

### B.4: Create fields.json with Image Coordinates
```json
{
  "pages": [{"page_number": 1, "image_width": 1700, "image_height": 2200}],
  "form_fields": [
    {
      "page_number": 1,
      "description": "Last name entry field",
      "field_label": "Last Name",
      "label_bounding_box": [120, 175, 242, 198],
      "entry_bounding_box": [255, 175, 720, 218],
      "entry_text": {"text": "Smith", "font_size": 10}
    }
  ]
}
```

Use `image_width`/`image_height` when using pixel coordinates from visual analysis.

### B.5: Validate
```bash
python scripts/check_bounding_boxes.py fields.json
```

## Hybrid Approach: Structure + Visual

1. Use Approach A for fields detected in `form_structure.json`
2. Convert PDF to images for visual analysis of missing fields
3. Convert image coordinates to PDF coordinates for missing fields:
   - pdf_x = image_x × (pdf_width / image_width)
   - pdf_y = image_y × (pdf_height / image_height)
4. Use a single coordinate system in `fields.json` (PDF coordinates with `pdf_width`/`pdf_height`)

## Step 2: Validate Before Filling
```bash
python scripts/check_bounding_boxes.py fields.json
```

## Step 3: Fill the Form
```bash
python scripts/fill_pdf_form_with_annotations.py <input.pdf> fields.json <output.pdf>
```

## Step 4: Verify Output
```bash
python scripts/convert_pdf_to_images.py <output.pdf> <verify_images/>
```

If text is mispositioned, check coordinate system and recalculate.
