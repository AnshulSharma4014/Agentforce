public without sharing class PermissionSetAssignmentQueuable implements Queueable, Finalizer {

    private List<User> newUsers;
    private Id customerCommunityPlusProfileId;
    private static final Set<String> PERMISSION_SET_NAMES = new Set<String>{'EinsteinGPTPromptTemplateUser', 'Customer_Community_Plus_Data_Cloud_Access', 'Northwind_Community_Policy_Access'};

    public PermissionSetAssignmentQueuable(List<User> newUsers) {
        this.newUsers = newUsers;
        this.customerCommunityPlusProfileId = getCustomerCommunityPlusProfileId();
    }

    public void execute(QueueableContext context) {
        System.attachFinalizer(this);
        
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        Set<Id> permissionSetIds = getPermissionSetIdsByName(PERMISSION_SET_NAMES);

        for (User user : newUsers) {
            if(user.ProfileId == customerCommunityPlusProfileId) {
                for (Id permissionSetId : permissionSetIds) {
                    assignments.add(new PermissionSetAssignment(
                        PermissionSetId = permissionSetId,
                        AssigneeId = user.Id
                    ));
                }
            }
        }

        if (!assignments.isEmpty()) {
            Database.insert(assignments, true, AccessLevel.SYSTEM_MODE);
        }
    }

    private Set<Id> getPermissionSetIdsByName(Set<String> permissionSetNames) {
        Set<Id> permissionSetIds = new Set<Id>();
        for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames WITH SYSTEM_MODE]) {
            permissionSetIds.add(ps.Id);
        }
        return permissionSetIds;
    }

    private Id getCustomerCommunityPlusProfileId() {
        return [SELECT Id FROM Profile WHERE Name = 'Customer Community Plus User' WITH SYSTEM_MODE LIMIT 1].Id;
    }

    public void execute(FinalizerContext ctx) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setSubject('Permission Set Assignment Job Completed');
        email.setPlainTextBody('The Permission Set Assignment job has completed successfully.');
        email.setToAddresses(new List<String>{'sharmaanshul99099@gmail.com'});
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{email});
    }
}