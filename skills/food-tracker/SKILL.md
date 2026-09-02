---
name: food-tracker
description: Log food and meals for Adrien or Ashley into the Tracking Engine Supabase tables, answer "what have I eaten today" and calorie/macro questions over any period, log food from a photo (nutrition label or a plate), and correct entries already logged. Use whenever the user mentions what they or Ashley ate, sends a food or nutrition-label photo, asks to log a meal, asks for totals, or asks to fix something logged earlier.
---

# Food tracker

Backend is the Supabase project **`Tracking-Engine`, project_id
`qarwswpnzignofrwdqye`**, reached through the Supabase MCP connector. Use
`execute_sql` for reads and writes; `apply_migration` only if the schema itself
ever needs changing, which it should not.

This replaces the old food tracker that wrote to the retired `Food-Tracker`
project. That project is gone — if a query returns nothing, the answer is "no
entries", never "wrong database".

## Two tables, two jobs

**`nutrition_items`** is a reference library of things eaten before, one row per
item at a stated serving size. It exists so the same food does not get
re-estimated differently every time.

```
id uuid · item text · serving text
calories numeric · protein_g numeric · carbs_g numeric · fat_g numeric · sugar_g numeric
```

**`food_log`** is what was actually eaten. One row per dish or meal, already
totalled — no ingredient breakdown.

```
id uuid · meal text · person text ('Adrien' | 'Ashley') · date date
calories numeric · protein_g numeric · carbs_g numeric · fat_g numeric · sugar_g numeric
```

`person` has a check constraint accepting only `Adrien` or `Ashley`. An insert
with anything else fails.

## Logging

1. **Parse what they said** into individual dishes with quantities. "two eggs
   and toast with butter" is one meal, three components.
2. **Look each component up first**:
   ```sql
   select * from nutrition_items where lower(item) like lower('%egg%');
   ```
   Reuse the stored values, scaled to the quantity actually eaten. This is the
   whole point of the table — consistency beats a fresh guess.
3. **For anything not in the library**, estimate from ordinary nutrition
   knowledge and insert it so next time is a lookup:
   ```sql
   insert into nutrition_items (item, serving, calories, protein_g, carbs_g, fat_g, sugar_g)
   values ('Scrambled egg', '1 large egg', 90, 6.3, 0.6, 7, 0.6);
   ```
   Do not insert branded or restaurant-specific items under a generic name.
   "Chipotle chicken burrito" and "burrito" are different rows.
4. **Write one `food_log` row per dish**, with the components summed:
   ```sql
   insert into food_log (meal, person, date, calories, protein_g, carbs_g, fat_g, sugar_g)
   values ('Two eggs, toast with butter', 'Adrien', current_date, 420, 18, 30, 25, 3);
   ```

Defaults: person is **Adrien** unless Ashley is named. Date is **today in
Pacific** unless they say otherwise — get it with
`TZ='America/Los_Angeles' date +%F`, never from UTC, or a late dinner lands on
tomorrow.

After writing, confirm in one line: what was logged, for whom, and the calorie
and protein totals. Nothing longer.

## Photos

**A nutrition label:** read the serving size first, then whether they ate one
serving or the container. Getting servings-per-container wrong is the single
most common way a label entry ends up 3x off. If the photo does not show the
serving size, ask rather than assume.

**A plate of food:** identify the dishes and estimate portions. Say what you
assumed — "assumed about 6 oz chicken, one cup rice" — so a wrong assumption is
correctable rather than buried. Log it the same way; the estimate goes in
`nutrition_items` only if it is a repeatable dish, not a one-off restaurant
plate.

## Answering questions

Today, for one person:
```sql
select meal, calories, protein_g, carbs_g, fat_g, sugar_g
  from food_log where person = 'Adrien' and date = current_date order by id;
```

Totals over a period, both people:
```sql
select person, date, sum(calories) cal, sum(protein_g) protein,
       sum(carbs_g) carbs, sum(fat_g) fat, sum(sugar_g) sugar
  from food_log where date >= current_date - 6
 group by 1, 2 order by 2 desc, 1;
```

Report what is there. A day with no rows is a day with no rows — do not
interpolate, average it away, or describe an empty day as "on track".

## Corrections

Find the row, then update or delete it:
```sql
select id, meal, date, calories from food_log
 where person = 'Adrien' and date = current_date order by id;

update food_log set calories = 520, protein_g = 22 where id = '<uuid>';
delete from food_log where id = '<uuid>';
```

Only ever delete a row the user has just identified. Never clear a day, a
person, or a range on your own initiative.

## Rules

- **Never invent precision.** Estimated macros are estimates; round to whole
  grams. Do not report 412.7 calories for a sandwich you guessed at.
- **Never guess between the two people.** If it is genuinely ambiguous who ate
  it, ask. A meal logged to the wrong person corrupts both their numbers.
- Two-retry cap on any failed write, then stop and say what failed. Do not
  retry a write that may have partially succeeded without checking first.
- The daily report (phase 3) reads `food_log` for the last 7 days for both
  people. Anything logged here shows up there the next morning.
