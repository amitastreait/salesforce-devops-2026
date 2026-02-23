/**
 * @description Trigger handler for Onboarding_Task__c.
 *              Follows the "one trigger per object, handler class" pattern.
 *              Delegates all logic to OnboardingService.
 */
public with sharing class OnboardingTaskTriggerHandler {

    /**
     * @description Entry point called by OnboardingTaskTrigger.
     * @param newList       Trigger.new
     * @param oldMap        Trigger.oldMap
     * @param operationType Trigger.operationType
     */
    public static void handle(
        List<Onboarding_Task__c> newList,
        Map<Id, Onboarding_Task__c> oldMap,
        System.TriggerOperation operationType
    ) {
        switch on operationType {
            when AFTER_UPDATE {
                // Recalculate if Is_Completed__c or Is_Rejected__c changed on at least one task
                List<Onboarding_Task__c> changed = new List<Onboarding_Task__c>();
                for (Onboarding_Task__c task : newList) {
                    Onboarding_Task__c old = oldMap.get(task.Id);
                    if (task.Is_Completed__c != old.Is_Completed__c
                            || task.Is_Rejected__c != old.Is_Rejected__c) {
                        changed.add(task);
                    }
                }
                if (!changed.isEmpty()) {
                    OnboardingService.recalculateCompletion(changed);
                }
            }
        }
    }
}