/**
 * @description Batch Apex class that sends reminder emails for Onboarding Requests
 *              starting in 3 days that still have incomplete tasks.
 *
 *              Replaces the direct service call in OnboardingReminderScheduler to
 *              safely process large data volumes without hitting the single-transaction
 *              Messaging.sendEmail governor limit (10 messages per transaction by default).
 *              Each batch chunk is a separate transaction with its own email allowance.
 *
 *              Implements Database.Stateful so the total processed count is preserved
 *              across chunks and visible in the finish() debug log.
 *
 * Execute manually via Anonymous Apex:
 *   Database.executeBatch(new OnboardingReminderBatch(), 50);
 */
public with sharing class OnboardingReminderBatch
        implements Database.Batchable<SObject>, Database.Stateful {

    private Integer processedCount = 0;

    // ─── start ────────────────────────────────────────────────────────────────

    /**
     * @description Returns a QueryLocator for all Onboarding Requests that start
     *              in exactly 3 days and are not yet Completed or Cancelled.
     *              Incomplete child tasks are included via subquery so
     *              OnboardingService.sendReminderEmails() can filter and build emails.
     * @param ctx BatchableContext provided by the platform
     * @return QueryLocator scoped to at-risk requests
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        Date targetDate = Date.today().addDays(3);
        return Database.getQueryLocator([
            SELECT Id, Name, Employee_Name__c, Start_Date__c,
                   Assigned_HR__c, Assigned_HR__r.Email,
                   (SELECT Id FROM Onboarding_Tasks__r WHERE Is_Completed__c = FALSE)
            FROM   Onboarding_Request__c
            WHERE  Start_Date__c = :targetDate
            AND    Status__c NOT IN ('Completed', 'Cancelled')
        ]);
    }

    // ─── execute ──────────────────────────────────────────────────────────────

    /**
     * @description Processes one chunk of at-risk requests and sends reminder emails
     *              via OnboardingService. Each chunk runs in its own transaction,
     *              preventing governor limit collisions on large data sets.
     * @param ctx      BatchableContext
     * @param requests Chunk of Onboarding_Request__c records from the QueryLocator
     */
    public void execute(Database.BatchableContext ctx, List<Onboarding_Request__c> requests) {
        OnboardingService.sendReminderEmails(requests);
        processedCount += requests.size();
    }

    // ─── finish ───────────────────────────────────────────────────────────────

    /**
     * @description Called once after all chunks are processed. Logs the total
     *              number of requests evaluated across all batch executions.
     * @param ctx BatchableContext
     */
    public void finish(Database.BatchableContext ctx) {
        System.debug(LoggingLevel.INFO,
            'OnboardingReminderBatch complete. Evaluated ' + processedCount + ' request(s).');
    }
}
