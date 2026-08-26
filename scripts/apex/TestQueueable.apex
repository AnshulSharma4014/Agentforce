User userRec = [SELECT Id, ProfileId FROM User WHERE Id = '005gL00000MvwCH' LIMIT 1];
System.enqueueJob(new PermissionSetAssignmentQueuable(new List<User>{userRec}));