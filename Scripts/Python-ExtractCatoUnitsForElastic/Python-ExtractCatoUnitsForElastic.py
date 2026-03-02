#!/usr/bin/env python3
"""Python-ExtractCatoUnitsForElastic

Connects to OrchEsbWskConfiguration, reads active Cato subscriptions,
extracts all Condition values for locator="LST_KST", aggregates unit codes by
Einrichtung (first up-to-4 leading digits), and writes newline-delimited JSON
objects (not a JSON array) to an output file in the current working directory.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract LST_KST unit values from active Cato subscriptions and "
            "write NDJSON grouped by Einrichtung."
        )
    )
    parser.add_argument(
        "--server",
        default="orchestrasql.wienkav.at",
        help="SQL Server host name.",
    )
    parser.add_argument(
        "--database",
        default="OrchEsbWskConfiguration",
        help="SQL Server database name.",
    )
    parser.add_argument(
        "--username",
        default="Orchestra_Access_User",
        help="SQL Server username.",
    )
    parser.add_argument(
        "--password",
        default="PASSWORD",
        help="SQL Server password.",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory where the output file is created.",
    )
    return parser.parse_args()


def fetch_subscription_xmls(server: str, database: str, username: str, password: str) -> list[str]:
    import pyodbc

    connection_string = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server={server};"
        f"Database={database};"
        f"Uid={username};"
        f"Pwd={password};"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
    )

    query = """
    select SubscriptionXml
    from [dbo].[Subscription] s
    inner join dbo.Party p on p.PartyId = s.PartyId
    where p.Name like '%Cato%' and s.Enabled = 1
    """

    with pyodbc.connect(connection_string) as connection:
        cursor = connection.cursor()
        cursor.execute(query)
        return [row[0] for row in cursor.fetchall() if row[0]]


def extract_units_from_subscription_xml(xml_text: str) -> list[str]:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []

    units: list[str] = []
    for node in root.iter("Condition"):
        if node.attrib.get("locator") != "LST_KST":
            continue

        raw_value = node.attrib.get("value", "")
        parts = [part.strip() for part in raw_value.split(",")]
        units.extend(part for part in parts if part)

    return units


def get_einrichtung(unit: str) -> str | None:
    match = re.match(r"^(\d{1,4})", unit)
    return match.group(1) if match else None


def aggregate_units_by_einrichtung(xml_rows: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, set[str]] = defaultdict(set)

    for xml_text in xml_rows:
        for unit in extract_units_from_subscription_xml(xml_text):
            einrichtung = get_einrichtung(unit)
            if not einrichtung:
                continue
            grouped[einrichtung].add(unit)

    return {key: sorted(values) for key, values in sorted(grouped.items())}


def write_ndjson(grouped_units: dict[str, list[str]], output_dir: str) -> Path:
    now = datetime.now(timezone.utc)
    timestamp = now.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    output_file = Path(output_dir) / f"{now.strftime('%Y%m%dT%H%M%SZ')}.json"

    lines = []
    for einrichtung, oes in grouped_units.items():
        payload = {
            "@timestamp": timestamp,
            "einrichtung": einrichtung,
            "oes": oes,
        }
        lines.append(json.dumps(payload, ensure_ascii=False, indent=2))

    output_file.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    return output_file


def main() -> int:
    args = parse_args()
    xml_rows = fetch_subscription_xmls(args.server, args.database, args.username, args.password)
    grouped_units = aggregate_units_by_einrichtung(xml_rows)
    output_file = write_ndjson(grouped_units, args.output_dir)
    print(f"Wrote {len(grouped_units)} records to {output_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
