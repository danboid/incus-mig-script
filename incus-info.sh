#!/bin/bash

# Incus info - creates a web page displaying the expiry dates (tags as used by incus-mig) for all locally running incus containers.

# By Dan MacDonald

# Adjust this path to wherever you would prefer to output the HTML file
OUTPUT_FILE="/var/www/html/index.html"

# Build the incus container info page
cat <<EOF > "$OUTPUT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Incus Container Status</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 40px; background-color: #f4f6f9; color: #333; }
        h1 { color: #1e293b; }
        table { width: 100%; border-collapse: collapse; margin-top: 20px; background: white; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); border-radius: 8px; overflow: hidden; }
        th, td { padding: 12px 15px; text-align: left; }
        th { background-color: #0f172a; color: white; font-weight: 600; }
        tr:nth-child(even) { background-color: #f8fafc; }
        tr:hover { background-color: #f1f5f9; }
        .footer { margin-top: 20px; font-size: 0.85em; color: #64748b; }
    </style>
</head>
<body>
    <h1>Active Incus Containers</h1>
    <table>
        <thead>
            <tr>
                <th>Container Name</th>
                <th>Expiry Date</th>
            </tr>
        </thead>
        <tbody>
EOF

# Get list of running containers and loop through them
incus list status=running -c n --format csv | while read -r container; do
    # Skip empty lines if any
    [ -z "$container" ] && continue

    # Fetch the expiry date using your config command
    expiry=$(incus config get "$container" user.expiry 2>/dev/null)

    # If no expiry is set, provide a fallback text
    if [ -z "$expiry" ]; then
        expiry="No Expiry Set"
    fi

    # Append row to HTML
    echo "            <tr><td><strong>$container</strong></td><td>$expiry</td></tr>" >> "$OUTPUT_FILE"
done

# Close the HTML tags
cat <<EOF >> "$OUTPUT_FILE"
        </tbody>
    </table>
    <div class="footer">Last updated: $(date "+%Y-%m-%d %H:%M:%S")</div>
</body>
</html>
EOF
