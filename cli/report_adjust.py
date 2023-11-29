#!/usr/bin/env python3

import argparse
import json
import os
import sys
import re
import traceback
from collections import defaultdict
import zlib
import base64

def decompress_data(data):
    if "compressed" in data and data["compressed"]:
        print("Decompressing...")
        data["results"] = json.loads(
            zlib.decompress(base64.b64decode(data["results"]))
        )
        data["project_metadata"] = json.loads(
            zlib.decompress(base64.b64decode(data["project_metadata"]))
        )
        data["compressed"] = False
    return data

def get_report(report):
    # Read and load the JSON from the file
    print(f"Reading report {report}...")
    with open(report, 'r') as file:
        loaded_report = json.load(file)
    

    report = decompress_data(loaded_report)
    # Check if the status field is valued "Failed"
    if report.get('status') != 'Completed':
        print("Status indicates failure")
        print(report.get('failure_reason'))
        

    # Define the required engines
    required_engines = ["class_members", "container", "rest_api", "functions", "TaintEngine", "persistency", "sensitivity_scorer", "GitURLEngine", "GitBlameEngine"]
    # Check if the engines array contains the required engines
    engines = report.get('engines', [])
    for engine in required_engines:
        if engine not in engines:
            print(f"Missing engine: {engine}")
    print("Got report")
    return report

def filter_functions(report):
    rest_api_files = set()
    artifacts = []
    filtered = 0
    for artifact in report['results']['artifacts']:
        if artifact['artifact_type'] == 'rest_api':
            rest_api_files.append(artifact["location"]["file_path"])

    for artifact in report['results']['artifacts']:
        if artifact['artifact_type'] == 'functions':
            if artifact["code_ref"]["file_path"] not in rest_api_files:
                filtered +=1
                continue

            
        artifacts.append(artifact)
    print(f"Filtered {filtered} function Artifacts")
    report["results"]["artifacts"] = artifacts
    return report


def match_flow(flow, regex):

    file_paths = [flow['metadata']["source"]["location"]["file_path"], flow['metadata']["source"]["location"]["file_path"]]
    for path in flow['metadata']['paths']:
        for part in path:
            file_paths.append(part['location']['file_path'])
    ret_val = False
    for path in file_paths:
        ret_val = ret_val or regex.match(path)
        if (regex.match(path)):
            print(f"Matched {file_paths} with {regex}")
    return ret_val

def too_long_flow(flow, max_length):
    for path in flow['metadata']['paths']:
        if len(path) > max_length:
            return True
    return False

def filter_cat_flow(flow_dict, regex, max_stack, category):
    new_dict ={}
    for rule_type, rule_list in flow_dict.items():
        new_rules = []
        filtered = 0
        for flow  in rule_list:
            if match_flow(flow, regex) or too_long_flow(flow, max_stack):
                    filtered += 1
                    continue
            
            new_rules.append(flow)
        print(f"Filtered {filtered} flows because they are too long/ matched exclusion pattern for {category} and {rule_type}")
    
        new_dict[rule_type] = new_rules
    return new_dict


def filter_flows(report, regex, max_stack):
    new_dict = {}
    for category, flow_dict in report['results']['flows_result']['flows_artifacts'].items():
        new_dict[category] = filter_cat_flow(flow_dict, regex, max_stack,category)
    report['results']['flows_result']['flows_artifacts'] = new_dict
    return report


def manipulate_report(report_path, pattern, max_stack):
    regex = re.compile(pattern, re.IGNORECASE)
    
    report = get_report(report_path)
    original_copy =os.path.join(os.path.dirname(report_path) ,"original_report.json")

    report = filter_functions(report)
    report = filter_flows(report, regex, max_stack)
    
    with open(report_path, 'w') as f:
        json.dump(report, f)
    print("Done")



def main():
    parser = argparse.ArgumentParser(
        description="check JSON report",
        usage="%(prog)s <root folder> <json file>"
    )

    parser.add_argument("report", type=str, help="The report location")
    parser.add_argument("-p", "--pattern", type=str, help="The pattern to discard",default=".*test.*")
    parser.add_argument("-m","--max_stack", type=int, help="Discard stacks longer than X",default=20)


  
    # Parse arguments
    args = parser.parse_args()
    return manipulate_report(report_path=args.report, pattern=args.pattern, max_stack=args.max_stack)


if __name__ == "__main__":
    rc = main()
    sys.exit(rc)
