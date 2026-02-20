/**
 * @description Scheduled Apex class that runs daily at 8 AM.
 *              Finds Onboarding Requests starting in 3 days with incomplete tasks
 *              and sends reminder emails to the assigned HR user.
 *
 * Schedule via Anonymous Apex:
 *   OnboardingReminderScheduler job = new OnboardingReminderScheduler();
 *   System.schedule('Daily Onboarding Reminders', '0 0 8 * * ?', job);
 */
public with sharing class OnboardingReminderScheduler implements Schedulable {

    /**
     * @description Called by the Salesforce scheduler. Fetches at-risk requests
     *              and delegates email sending to OnboardingService.
     * @param ctx SchedulableContext provided by the platform
     */
    public void execute(SchedulableContext ctx) {
        List<Onboarding_Request__c> requests = OnboardingService.getRequestsNeedingReminder();
        if (!requests.isEmpty()) {
            OnboardingService.sendReminderEmails(requests);
        }
    }
}