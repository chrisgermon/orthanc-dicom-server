#!/bin/bash
# Orthanc DICOM Server Management Script
# Usage: ./manage.sh <command> [options]

ORTHANC_URL="${ORTHANC_URL:-https://localhost}"
CURL="curl -sk"

usage() {
    cat <<EOF
Orthanc DICOM Server Management

Usage: $(basename "$0") <command> [options]

Commands:
  status              Show server status and statistics
  studies             List all studies
  study <id>          Show study details
  delete-study <id>   Delete a study
  delete-series <id>  Delete a series
  send-study <id> <modality>    Send study to a DICOM modality
  send-series <id> <modality>   Send series to a DICOM modality
  modalities          List configured DICOM modalities
  echo <modality>     Test connectivity to a modality (C-ECHO)
  patients            List all patients
  find <query>        Search studies (by patient name, ID, etc.)
  modify-patient <study-id>     Modify patient info on a study
  export <id> <path>  Export study as DICOM files
  jobs                List running jobs
  job <id>            Show job status
  upload <path>       Upload DICOM file(s)
  disk-usage          Show storage usage
  cleanup <days>      Delete studies older than N days

EOF
}

case "${1}" in
  status)
    echo "=== Orthanc Server Status ==="
    ${CURL} "${ORTHANC_URL}/orthanc/system" | python3 -m json.tool
    echo ""
    echo "=== Statistics ==="
    ${CURL} "${ORTHANC_URL}/orthanc/statistics" | python3 -m json.tool
    ;;

  studies)
    echo "=== All Studies ==="
    STUDIES=$(${CURL} "${ORTHANC_URL}/orthanc/studies")
    for STUDY in $(echo "${STUDIES}" | python3 -c "import sys,json; [print(s) for s in json.load(sys.stdin)]" 2>/dev/null); do
      INFO=$(${CURL} "${ORTHANC_URL}/orthanc/studies/${STUDY}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
mt = d.get('MainDicomTags', {})
print(f\"  {d['ID'][:12]}  {mt.get('PatientName','N/A'):30s}  {mt.get('StudyDate','N/A'):10s}  {mt.get('StudyDescription','N/A')}\")
" 2>/dev/null)
      echo "${INFO}"
    done
    ;;

  study)
    [ -z "$2" ] && echo "Usage: $0 study <study-id>" && exit 1
    ${CURL} "${ORTHANC_URL}/orthanc/studies/${2}" | python3 -m json.tool
    ;;

  delete-study)
    [ -z "$2" ] && echo "Usage: $0 delete-study <study-id>" && exit 1
    read -p "Delete study ${2}? (y/N) " confirm
    [ "$confirm" = "y" ] && ${CURL} -X DELETE "${ORTHANC_URL}/orthanc/studies/${2}" && echo "Deleted." || echo "Cancelled."
    ;;

  delete-series)
    [ -z "$2" ] && echo "Usage: $0 delete-series <series-id>" && exit 1
    read -p "Delete series ${2}? (y/N) " confirm
    [ "$confirm" = "y" ] && ${CURL} -X DELETE "${ORTHANC_URL}/orthanc/series/${2}" && echo "Deleted." || echo "Cancelled."
    ;;

  send-study)
    [ -z "$3" ] && echo "Usage: $0 send-study <study-id> <modality-name>" && exit 1
    echo "Sending study ${2} to modality ${3}..."
    ${CURL} -X POST "${ORTHANC_URL}/orthanc/modalities/${3}/store" \
      -H "Content-Type: application/json" \
      -d "\"${2}\"" | python3 -m json.tool
    ;;

  send-series)
    [ -z "$3" ] && echo "Usage: $0 send-series <series-id> <modality-name>" && exit 1
    echo "Sending series ${2} to modality ${3}..."
    ${CURL} -X POST "${ORTHANC_URL}/orthanc/modalities/${3}/store" \
      -H "Content-Type: application/json" \
      -d "\"${2}\"" | python3 -m json.tool
    ;;

  modalities)
    echo "=== Configured Modalities ==="
    ${CURL} "${ORTHANC_URL}/orthanc/modalities?expand" | python3 -m json.tool
    ;;

  echo)
    [ -z "$2" ] && echo "Usage: $0 echo <modality-name>" && exit 1
    echo "Testing connectivity to ${2}..."
    ${CURL} -X POST "${ORTHANC_URL}/orthanc/modalities/${2}/echo" | python3 -m json.tool
    ;;

  patients)
    echo "=== All Patients ==="
    PATIENTS=$(${CURL} "${ORTHANC_URL}/orthanc/patients")
    for PAT in $(echo "${PATIENTS}" | python3 -c "import sys,json; [print(p) for p in json.load(sys.stdin)]" 2>/dev/null); do
      INFO=$(${CURL} "${ORTHANC_URL}/orthanc/patients/${PAT}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
mt = d.get('MainDicomTags', {})
print(f\"  {d['ID'][:12]}  {mt.get('PatientName','N/A'):30s}  {mt.get('PatientID','N/A'):15s}  Studies: {len(d.get('Studies',[]))}\")
" 2>/dev/null)
      echo "${INFO}"
    done
    ;;

  find)
    [ -z "$2" ] && echo "Usage: $0 find <query>" && exit 1
    ${CURL} -X POST "${ORTHANC_URL}/orthanc/tools/find" \
      -H "Content-Type: application/json" \
      -d "{\"Level\":\"Study\",\"Query\":{\"PatientName\":\"*${2}*\"},\"Expand\":true}" | python3 -m json.tool
    ;;

  modify-patient)
    [ -z "$2" ] && echo "Usage: $0 modify-patient <study-id>" && exit 1
    echo "Current study info:"
    ${CURL} "${ORTHANC_URL}/orthanc/studies/${2}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
mt = d.get('MainDicomTags', {})
print(f\"  Patient Name: {mt.get('PatientName','N/A')}\")
print(f\"  Patient ID:   {mt.get('PatientID','N/A')}\")
print(f\"  Study Desc:   {mt.get('StudyDescription','N/A')}\")
"
    echo ""
    read -p "New Patient Name (leave blank to keep): " new_name
    read -p "New Patient ID (leave blank to keep): " new_id

    REPLACE="{}"
    if [ -n "$new_name" ] && [ -n "$new_id" ]; then
      REPLACE="{\"PatientName\":\"${new_name}\",\"PatientID\":\"${new_id}\"}"
    elif [ -n "$new_name" ]; then
      REPLACE="{\"PatientName\":\"${new_name}\"}"
    elif [ -n "$new_id" ]; then
      REPLACE="{\"PatientID\":\"${new_id}\"}"
    else
      echo "No changes specified."
      exit 0
    fi

    echo "Modifying study..."
    ${CURL} -X POST "${ORTHANC_URL}/orthanc/studies/${2}/modify" \
      -H "Content-Type: application/json" \
      -d "{\"Replace\":${REPLACE},\"Force\":true}" | python3 -m json.tool
    ;;

  export)
    [ -z "$3" ] && echo "Usage: $0 export <study-id> <output-path>" && exit 1
    mkdir -p "${3}"
    echo "Exporting study ${2} to ${3}..."
    ${CURL} "${ORTHANC_URL}/orthanc/studies/${2}/archive" -o "${3}/study-${2}.zip"
    echo "Saved to ${3}/study-${2}.zip"
    ;;

  jobs)
    echo "=== Running Jobs ==="
    ${CURL} "${ORTHANC_URL}/orthanc/jobs?expand" | python3 -m json.tool
    ;;

  job)
    [ -z "$2" ] && echo "Usage: $0 job <job-id>" && exit 1
    ${CURL} "${ORTHANC_URL}/orthanc/jobs/${2}" | python3 -m json.tool
    ;;

  upload)
    [ -z "$2" ] && echo "Usage: $0 upload <dicom-file-or-directory>" && exit 1
    if [ -d "$2" ]; then
      echo "Uploading all DICOM files from ${2}..."
      find "$2" -type f \( -name "*.dcm" -o -name "*.DCM" -o ! -name "*.*" \) | while read -r f; do
        echo "  Uploading: $(basename "$f")"
        ${CURL} -X POST "${ORTHANC_URL}/orthanc/instances" \
          -H "Content-Type: application/dicom" \
          --data-binary "@${f}" > /dev/null
      done
      echo "Done."
    else
      echo "Uploading ${2}..."
      ${CURL} -X POST "${ORTHANC_URL}/orthanc/instances" \
        -H "Content-Type: application/dicom" \
        --data-binary "@${2}" | python3 -m json.tool
    fi
    ;;

  disk-usage)
    echo "=== Disk Usage ==="
    ${CURL} "${ORTHANC_URL}/orthanc/statistics" | python3 -c "
import sys, json
s = json.load(sys.stdin)
size_mb = s.get('TotalDiskSizeMB', s.get('TotalDiskSize', 0) / 1048576)
print(f\"  Total Studies:    {s.get('CountStudies', 'N/A')}\")
print(f\"  Total Series:    {s.get('CountSeries', 'N/A')}\")
print(f\"  Total Instances: {s.get('CountInstances', 'N/A')}\")
print(f\"  Total Patients:  {s.get('CountPatients', 'N/A')}\")
print(f\"  Disk Usage:      {size_mb:.1f} MB\")
"
    ;;

  cleanup)
    [ -z "$2" ] && echo "Usage: $0 cleanup <days-old>" && exit 1
    CUTOFF=$(date -d "-${2} days" +%Y%m%d 2>/dev/null || date -v-${2}d +%Y%m%d)
    echo "Finding studies older than ${2} days (before ${CUTOFF})..."
    RESULTS=$(${CURL} -X POST "${ORTHANC_URL}/orthanc/tools/find" \
      -H "Content-Type: application/json" \
      -d "{\"Level\":\"Study\",\"Query\":{\"StudyDate\":\"-${CUTOFF}\"},\"Expand\":true}")
    COUNT=$(echo "${RESULTS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    echo "Found ${COUNT} studies to delete."
    read -p "Proceed with deletion? (y/N) " confirm
    if [ "$confirm" = "y" ]; then
      echo "${RESULTS}" | python3 -c "
import sys, json
studies = json.load(sys.stdin)
for s in studies:
    print(s['ID'])
" | while read -r sid; do
        ${CURL} -X DELETE "${ORTHANC_URL}/orthanc/studies/${sid}" > /dev/null
        echo "  Deleted: ${sid}"
      done
      echo "Cleanup complete."
    else
      echo "Cancelled."
    fi
    ;;

  *)
    usage
    ;;
esac
