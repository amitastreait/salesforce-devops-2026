/**
 * @description Trigger handler for Onboarding_Request__c.
 *              Follows the "one trigger per object, handler class" pattern.
 *              All business logic is delegated to OnboardingService.
 */
public with sharing class OnboardingRequestTriggerHandler {

    /**
     * @description Entry point called by OnboardingRequestTrigger.
     * @param newList       Trigger.new
     * @param oldMap        Trigger.oldMap
     * @param operationType Trigger.operationType
     */
    public static void handle(
        List<Onboarding_Request__c> newList,
        Map<Id, Onboarding_Request__c> oldMap,
        System.TriggerOperation operationType
    ) {
        switch on operationType {
            when BEFORE_UPDATE {
                // Block Status='Completed' if any tasks are still open (not completed or rejected)
                OnboardingService.validateCompletion(newList, oldMap);
            }
            when AFTER_INSERT {
                OnboardingService.createDefaultTasks(newList);
            }
            when AFTER_UPDATE {
                // Create Employee__c record when request transitions to Completed
                OnboardingService.handleCompletionSideEffects(newList, oldMap);
            }
        }
    }
}
