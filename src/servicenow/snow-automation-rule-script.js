/**
 * ServiceNow Business Rule: Fire Azure Monitor Close Webhook on Incident Completion
 *
 * Table:    incident
 * When:     after update
 * Condition: current.state == 6 (Resolved) && current.correlation_id starts with /subscriptions/
 *
 * Instructions:
 *   1. In your ServiceNow PDI or production instance, go to:
 *      System Definition > Business Rules > New
 *   2. Configure:
 *      - Name:    Azure Monitor Close Alert
 *      - Table:   Incident [incident]
 *      - Advanced: checked
 *      - When:    after
 *      - Update:  checked
 *      - Condition: current.state == 6 && current.correlation_id.startsWith('/subscriptions/')
 *   3. In the Script tab, paste this script.
 *   4. Replace LOGIC_APP_WEBHOOK_URL with the HTTP POST URL from the Logic App
 *      Azure-Monitor-Close-ITSM-HTTP-API (found in the Logic App trigger).
 *
 * How it works:
 *   - When an Azure Monitor-sourced incident (identified by correlation_id containing
 *     the Azure subscription path) is marked Resolved (state=6), this rule fires a
 *     webhook to the Azure-Monitor-Close-ITSM-HTTP-API Logic App.
 *   - The Logic App then closes the corresponding Azure Monitor alert and writes the
 *     SNOW ticket number to the Azure Monitor alert history.
 */

(function executeRule(current, previous) {

    // Replace with your Logic App Azure-Monitor-Close-ITSM-HTTP-API webhook URL
    var LOGIC_APP_WEBHOOK_URL = "https://prod-XX.eastus.logic.azure.com/workflows/<workflow-id>/triggers/manual/paths/invoke?api-version=2016-10-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=<signature>";

    // Only fire for Azure Monitor sourced incidents
    // correlation_id is set to the Azure Monitor alertId during incident creation
    var correlationId = current.correlation_id.toString();
    if (!correlationId || correlationId.indexOf('/subscriptions/') === -1) {
        gs.info('Azure Monitor Business Rule: skipping — not an Azure Monitor sourced incident. correlation_id: ' + correlationId);
        return;
    }

    var payload = {
        incidentNumber: current.number.toString(),
        incidentSysId: current.sys_id.toString(),
        correlationId: correlationId,
        state: current.state.toString(),
        closeCode: current.close_code.toString(),
        closeNotes: current.close_notes.toString(),
        resolvedAt: current.resolved_at.toString(),
        resolvedBy: current.resolved_by.getDisplayValue()
    };

    var request = new sn_ws.RESTMessageV2();
    request.setEndpoint(LOGIC_APP_WEBHOOK_URL);
    request.setHttpMethod('POST');
    request.setRequestHeader('Content-Type', 'application/json');
    request.setRequestBody(JSON.stringify(payload));

    try {
        var response = request.execute();
        var httpStatus = response.getStatusCode();
        gs.info('Azure Monitor Business Rule: webhook fired. HTTP status: ' + httpStatus + ', incident: ' + current.number);

        if (httpStatus < 200 || httpStatus >= 300) {
            gs.error('Azure Monitor Business Rule: webhook returned non-success status ' + httpStatus + ' for incident ' + current.number);
        }
    } catch (ex) {
        gs.error('Azure Monitor Business Rule: webhook call failed. Error: ' + ex.message + ', incident: ' + current.number);
    }

})(current, previous);
