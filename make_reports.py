"""Builds Data_Cleaning_Report.pdf and Data_Quality_Report.pdf from the database. Needs: pip install reportlab"""
import getpass, os
import psycopg2
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle

DB_NAME = "nyc311"
OUT = os.path.dirname(os.path.abspath(__file__))
ss = getSampleStyleSheet()

def table(data, widths=None, status_col=None):
    t = Table(data, colWidths=widths, repeatRows=1)
    style = [("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F3A5F")), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
             ("FONTSIZE", (0, 0), (-1, -1), 8), ("GRID", (0, 0), (-1, -1), 0.4, colors.grey),
             ("VALIGN", (0, 0), (-1, -1), "TOP"),
             ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F2F5F9")])]
    if status_col is not None:
        for i, row in enumerate(data[1:], start=1):
            style.append(("TEXTCOLOR", (status_col, i), (status_col, i),
                          colors.HexColor("#1B7F3B") if row[status_col] == "PASS" else colors.HexColor("#B00020")))
    t.setStyle(TableStyle(style))
    return t

def P(text, style="BodyText"):
    return Paragraph(text, ss[style])

def main():
    pw = os.environ.get("PGPASSWORD") or getpass.getpass("Postgres password: ")
    conn = psycopg2.connect(host="127.0.0.1", port=5432, dbname=DB_NAME, user="postgres", password=pw)
    cur = conn.cursor()

    # ---------- Data Cleaning Report ----------
    cur.execute("SELECT metric, value FROM project_staging.etl_log ORDER BY log_id")
    log = [[m, f"{v:,}"] for m, v in cur.fetchall()]
    examples = []
    for col in ("city", "borough", "complaint_type"):
        cur.execute(f"""SELECT DISTINCT {col}, project_staging.clean_text({col}) FROM project_staging.raw_nyc311
                        WHERE {col} IS NOT NULL AND {col} <> project_staging.clean_text({col}) LIMIT 6""")
        examples += [[col, repr(b), repr(a)] for b, a in cur.fetchall()]
    doc = SimpleDocTemplate(os.path.join(OUT, "Data_Cleaning_Report.pdf"), pagesize=A4)
    s = [P("Data Cleaning Report - Phase 2", "Title"),
         P("Pipeline: CSV files &rarr; project_staging &rarr; project_dw &rarr; project_reporting. "
           "Sources: NYC311data.csv, fhrw-4uyv.csv, PLUTO borough files (BK, BX, MN, QN, SI)."), Spacer(1, 10),
         P("Transformations applied", "Heading2"),
         P("1. <b>Remove duplicates</b>: one row per unique_key (NYC311 preferred over the HPD extract); rows without a key or a valid created date are dropped.<br/>"
           "2. <b>Handle NULLs</b>: missing agency, complaint type, descriptor, status, borough, ZIP and channel become 'Unknown'; "
           "closed dates earlier than created dates are set to NULL; out-of-range coordinates are set to NULL.<br/>"
           "3. <b>Standardize text</b>: trim, collapse spaces, Title Case (' lahore ' / 'LAHORE' &rarr; 'Lahore'); ZIP reduced to 5 digits.<br/>"
           "4. <b>Convert data types</b>: text &rarr; bigint (keys), timestamp (dates), numeric (coordinates); resolution_hours derived."),
         Spacer(1, 10), P("Before / after examples (raw 311 values)", "Heading2"),
         table([["Column", "Before", "After"]] + (examples or [["-", "no differences found", "-"]]), [90, 200, 200]),
         Spacer(1, 10), P("Cleaning metrics", "Heading2"), table([["Metric", "Rows"]] + log, [330, 120])]
    doc.build(s)

    # ---------- Data Quality Report ----------
    cur.execute("SELECT category, check_name, expected, actual, rule, status FROM project_reporting.dq_results ORDER BY check_id")
    rows = cur.fetchall()
    counts = []
    for t in ("project_staging.stg_service_request", "project_dw.dim_date", "project_dw.dim_agency",
              "project_dw.dim_complaint_type", "project_dw.dim_location", "project_dw.dim_status",
              "project_dw.dim_channel", "project_dw.fact_service_request"):
        cur.execute(f"SELECT count(*) FROM {t}")
        counts.append([t, f"{cur.fetchone()[0]:,}"])
    passed = sum(r[5] == "PASS" for r in rows)
    doc = SimpleDocTemplate(os.path.join(OUT, "Data_Quality_Report.pdf"), pagesize=A4)
    s = [P("Data Quality Report - Phase 2", "Title"),
         P(f"<b>{passed} of {len(rows)} checks passed.</b> Rule 'eq' = actual must equal expected (0 differences); "
           "'lte' = actual percentage must not exceed the threshold."), Spacer(1, 10),
         P("Row counts per layer", "Heading2"), table([["Table", "Rows"]] + counts, [330, 120]), Spacer(1, 10)]
    for cat in ("Completeness", "Accuracy", "Integrity"):
        s += [P(cat, "Heading2"),
              table([["Check", "Expected", "Actual", "Rule", "Status"]] +
                    [[Paragraph(r[1], ss["BodyText"]), str(r[2]), str(r[3]), r[4], r[5]] for r in rows if r[0] == cat],
                    [250, 55, 55, 40, 50], status_col=4), Spacer(1, 8)]
    doc.build(s)
    conn.close()
    print("Created Data_Cleaning_Report.pdf and Data_Quality_Report.pdf")

if __name__ == "__main__":
    main()
