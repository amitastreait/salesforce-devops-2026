// Permission Set API Names
Set<String> permSetNames = new Set<String>{
    'Example_permissionset',
    'Stripe_Object_Permissions'
};

// User Emails
Set<String> userEmails = new Set<String>{'amitsingh536@agentforce.com'};

// Fetch Permission Sets
Map<String, Id> permSetMap = new Map<String, Id>();
for(PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN :permSetNames ]){
    permSetMap.put(ps.Name, ps.Id);
}

// Fetch Users
Map<Id, User> userMap = new Map<Id, User>([SELECT Id, Email FROM User WHERE Email IN :userEmails ]);

Set<Id> userIds = userMap.keySet();
Set<Id> permSetIds = new Set<Id>(permSetMap.values());

// Fetch Existing Assignments
Set<String> existingAssignments = new Set<String>();

for(PermissionSetAssignment psa : [SELECT AssigneeId, PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId IN :userIds AND PermissionSetId IN :permSetIds]){
    existingAssignments.add(psa.AssigneeId + '-' + psa.PermissionSetId);
}

// Prepare new assignments
List<PermissionSetAssignment> psaList = new List<PermissionSetAssignment>();

for(Id userId : userIds){
    for(Id psId : permSetIds){
        String key = userId + '-' + psId;
        
        // Only assign if not already assigned
        if(!existingAssignments.contains(key)){
            psaList.add(new PermissionSetAssignment(
                AssigneeId = userId,
                PermissionSetId = psId
            ));
        }
    }
}

// Insert safely
if(!psaList.isEmpty()){
    insert psaList;
    System.debug('Assigned ' + psaList.size() + ' Permission Set(s)');
} else {
    System.debug('All users already have all Permission Sets.');
}


// ── Run anonymous Apex ────────────────────────────────
// sf apex run --file scripts/apex/hello.apex

// ── Stream live debug logs ────────────────────────────
// sf apex tail log --target-org mySandbox