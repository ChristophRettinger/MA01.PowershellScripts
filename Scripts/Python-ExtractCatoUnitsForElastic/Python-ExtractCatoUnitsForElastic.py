#!/usr/bin/env python3
"""Python-ExtractCatoUnitsForElastic

Connects to OrchEsbWskConfiguration, reads active Cato subscriptions,
extracts all Condition values for locator="LST_KST", aggregates unit codes by
Einrichtung (first up-to-4 leading digits), and writes newline-delimited JSON
objects (not a JSON array) to an output file in the current working directory.
Requires Python 3.9.25 or newer.
"""


import argparse
import json
import re
from collections import defaultdict
from datetime import datetime
import io
import os
import sys
import xml.etree.ElementTree as ET


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Extract LST_KST unit values from active Cato subscriptions and "
            "write NDJSON grouped by Einrichtung."
        )
    )
    parser.add_argument("--server", default="orchestrasql.wienkav.at", help="SQL Server host name.")
    parser.add_argument("--database", default="OrchEsbWskConfiguration", help="SQL Server database name.")
    parser.add_argument("--username", default="Orchestra_Access_User", help="SQL Server username.")
    parser.add_argument("--password", default="PASSWORD", help="SQL Server password.")
    parser.add_argument("--output-dir", default=".", help="Directory where the output file is created.")
    return parser.parse_args()


def fetch_subscription_xmls(server, database, username, password):
    try:
        import pyodbc
    except ImportError as exc:
        message = str(exc)
        if "libodbc.so.2" in message:
            raise RuntimeError(
                "pyodbc is installed, but the unixODBC runtime library is missing (libodbc.so.2). "
                "Install unixODBC on the host, for example: 'dnf install unixODBC' or 'apt-get install unixodbc', "
                "then rerun the script."
            ) from exc
        raise RuntimeError(
            "The 'pyodbc' module is not available. Install it with 'pip install pyodbc' and rerun the script."
        ) from exc

    available_drivers = set(pyodbc.drivers())
    preferred_drivers = ["ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server"]
    selected_driver = None
    for candidate in preferred_drivers:
        if candidate in available_drivers:
            selected_driver = candidate
            break

    if not selected_driver:
        ordered = sorted(available_drivers)
        message = "No supported SQL Server ODBC driver found."
        if ordered:
            raise RuntimeError(
                "{0} Installed drivers: {1}. Install 'ODBC Driver 18 for SQL Server' or 'ODBC Driver 17 for SQL Server'.".format(
                    message,
                    ", ".join(ordered),
                )
            )
        raise RuntimeError(
            "{0} No ODBC drivers are currently registered. Install unixODBC and a SQL Server ODBC driver (18 or 17).".format(
                message
            )
        )

    connection_string = (
        "Driver={{{0}}};"
        "Server={1};"
        "Database={2};"
        "Uid={3};"
        "Pwd={4};"
        "Encrypt=yes;"
        "TrustServerCertificate=yes;"
    ).format(selected_driver, server, database, username, password)

    query = """
    select SubscriptionXml
    from [dbo].[Subscription] s
    inner join dbo.Party p on p.PartyId = s.PartyId
    where p.Name like '%Cato%' and s.Enabled = 1
    """

    try:
        connection = pyodbc.connect(connection_string)
    except pyodbc.Error as exc:
        raise RuntimeError(
            "Unable to connect with ODBC driver '{0}'. Verify driver installation and SQL connectivity. pyodbc error: {1}".format(
                selected_driver,
                exc,
            )
        ) from exc
    try:
        cursor = connection.cursor()
        cursor.execute(query)
        return [row[0] for row in cursor.fetchall() if row[0]]
    finally:
        connection.close()


def extract_units_from_subscription_xml(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return []

    units = []
    for node in root.iter("Condition"):
        if node.attrib.get("locator") != "LST_KST":
            continue

        raw_value = node.attrib.get("value", "")
        parts = [part.strip() for part in raw_value.split(",")]
        units.extend(part for part in parts if part)

    return units


def get_einrichtung(unit):
    match = re.match(r"^(\d{1,4})", unit)
    if not match:
        return None
    return match.group(1)


def aggregate_units_by_einrichtung(xml_rows):
    grouped = defaultdict(set)

    for xml_text in xml_rows:
        for unit in extract_units_from_subscription_xml(xml_text):
            einrichtung = get_einrichtung(unit)
            if not einrichtung:
                continue
            grouped[einrichtung].add(unit)

    output = {}
    for key in sorted(grouped.keys()):
        output[key] = sorted(grouped[key])
    return output


def write_ndjson(grouped_units, output_dir):
    now = datetime.utcnow()
    timestamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    output_file = os.path.join(output_dir, now.strftime("%Y%m%dT%H%M%SZ") + ".json")

    lines = []
    for einrichtung, oes in grouped_units.items():
        payload = {
            "@timestamp": timestamp,
            "einrichtung": einrichtung,
            "oes": oes,
        }
        lines.append(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))

    content = "\n".join(lines) + ("\n" if lines else "")
    with io.open(output_file, "w", encoding="utf-8") as handle:
        handle.write(content)
    return output_file


def main():
    args = parse_args()
    try:
        xml_rows = fetch_subscription_xmls(args.server, args.database, args.username, args.password)
    except RuntimeError as exc:
        print("Error: {0}".format(exc), file=sys.stderr)
        return 1

    grouped_units = aggregate_units_by_einrichtung(xml_rows)
    output_file = write_ndjson(grouped_units, args.output_dir)
    print("Wrote {0} records to {1}".format(len(grouped_units), output_file))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
