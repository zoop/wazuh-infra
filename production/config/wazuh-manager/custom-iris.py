#!/usr/bin/env python3
"""
Wazuh → DFIR-IRIS integration
Forwards Wazuh alerts (level 7+) to IRIS as cases via the IRIS API.
"""

import sys
import json
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

alert_file = open(sys.argv[1])
alert = json.load(alert_file)
alert_file.close()

hook_url = sys.argv[3]
api_key  = sys.argv[2]

payload = {
    "case_name":        f"[Wazuh] {alert.get('rule', {}).get('description', 'Alert')}",
    "case_description": json.dumps(alert, indent=2),
    "case_customer":    1,
    "case_soc_id":      f"wazuh-{alert.get('id', 'unknown')}",
    "custom_attributes": {}
}

headers = {
    "Authorization": f"Bearer {api_key}",
    "Content-Type":  "application/json"
}

try:
    response = requests.post(
        hook_url,
        json=payload,
        headers=headers,
        verify=False,
        timeout=10
    )
    if response.status_code == 200:
        print(f"IRIS case created: {response.json().get('data', {}).get('case_id')}")
    else:
        print(f"IRIS error {response.status_code}: {response.text}", file=sys.stderr)
except Exception as e:
    print(f"Integration failed: {e}", file=sys.stderr)
