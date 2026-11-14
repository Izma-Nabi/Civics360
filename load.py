import csv
import re
import getpass
import psycopg2

DB = dict(host="127.0.0.1", port=5432, dbname="nyc311",
          user="postgres", password=getpass.getpass("Postgres password: "))

FILES = {
    "hpd_311":          [r"D:\data\fhrw-4uyv.csv"],
    "nyc_311_requests": [r"D:\data\NYC311data.csv"],
    "pluto":            [rf"D:\data\{b}_18v1.csv" for b in ("BK", "BX", "MN", "QN", "SI")],
}

def clean_cols(header):
    seen, out = set(), []
    for i, col in enumerate(header):
        c = re.sub(r"[^0-9a-zA-Z]+", "_", col.strip()).strip("_").lower() or f"col_{i}"
        if c[0].isdigit():
            c = "c_" + c
        base, n = c, 1
        while c in seen:
            n += 1
            c = f"{base}_{n}"
        seen.add(c)
        out.append(c)
    return out

conn = psycopg2.connect(**DB)
cur = conn.cursor()

for table, paths in FILES.items():
    with open(paths[0], newline="", encoding="utf-8-sig") as f:
        header = next(csv.reader(f))
    cols = clean_cols(header)

    cur.execute(f'DROP TABLE IF EXISTS "{table}"')
    cur.execute(f'CREATE TABLE "{table}" (' + ", ".join(f'"{c}" TEXT' for c in cols) + ")")
    col_list = ", ".join(f'"{c}"' for c in cols)

    for path in paths:
        with open(path, encoding="utf-8-sig") as f:
            cur.copy_expert(
                f'COPY "{table}" ({col_list}) FROM STDIN WITH (FORMAT csv, HEADER true)', f
            )
        print("loaded", path)
    conn.commit()

    cur.execute(f'SELECT COUNT(*) FROM "{table}"')
    print(f"{table}: {cur.fetchone()[0]} rows loaded")

cur.close()
conn.close()