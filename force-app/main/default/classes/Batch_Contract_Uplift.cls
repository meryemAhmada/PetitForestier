global class Batch_Contract_Uplift implements Database.Batchable<sObject>, Database.Stateful,Database.AllowsCallouts{
    
    //To avoid Cumulative Timeout Limitation, this batch must be ran with 3 batch size maximum
    //Map to store calculated rates by Frequence and entity
    Map<String , List<Integer>> rateByEntityAndFrequence;
    List<Integer> years;
    Map<String , String> periods;
    Date todayDate;
    Boolean sendEmail;

    List<String> logs;

    public Batch_Contract_Uplift(Boolean doSendEmail){
        sendEmail = doSendEmail;
        logs = new List<String> ();
        rateByEntityAndFrequence = new Map<String , List<Integer>>();
        todayDate = Date.Today();
        years = new List<Integer> {todayDate.year() , todayDate.year() - 1};
        periods = new Map<String , String>();
        periods.put('Mensuelle' , 'M'+todayDate.month());
        periods.put('Trimestrielle' , 'T'+math.round((todayDate.month()+1)/3.0));
        periods.put('Annuelle' , 'Y');
        
    }
    
	global Database.QueryLocator start(Database.BatchableContext bc) {
        String notEligibile = 'Pas d\'indexation';
        return Database.getQueryLocator('SELECT Id , Legal_Entity__c , Legal_Entity__r.Update_Rate_Frequency__c , Uplift_Mode__c , Next_Date_Uplift__c , Negociated_Rate__c, SBQQ__Order__c FROM Contract Where Next_Date_Uplift__c =: todayDate and Uplift_Mode__c != :notEligibile order by Legal_Entity__r.name , contract.Legal_Entity__r.Update_Rate_Frequency__c');
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope){
        
        List<Contract> contracts = (List<Contract>) scope;
        Map<Id , Decimal> RTAByOrder = new Map<Id , Decimal>();
         
        Set<String> entities = new Set<String>();
        Map<Id , List<Uplift_Rate__c>>  upliftRatesByEntity = new Map<Id , List<Uplift_Rate__c>>();
        Decimal actualRateToApply;
        Decimal previousRateToApply;
        Decimal rateToApply;
        List<SBQQ__Quote__c> quotes;

        if(sendEmail) logs.add('*** , Processing...');
        system.debug('*** Batch_Contract_Uplift >> Processing...');

        try{
            //Get UpliftRates By Entities
            for(Contract contract : contracts){
                if(! rateByEntityAndFrequence.containsKey(contract.Legal_Entity__c+';'+contract.Legal_Entity__r.Update_Rate_Frequency__c )){
                    entities.add(contract.Legal_Entity__c);
                }
            }

            if(sendEmail) logs.add('*** , rateByEntityAndFrequence: '+rateByEntityAndFrequence);
            
            //Set upliftRatesByEntity Map : 
            for(Uplift_Rate__c upliftRate : [Select Id , Index__c , Index_Year__c , Index_Period__c , Legal_Entity__c From Uplift_Rate__c Where Legal_Entity__c In :entities And Index_Year__c In :years And Index_Period__c In :periods.values() ]){
                if(!upliftRatesByEntity.containskey(upliftRate.Legal_Entity__c)){
                    upliftRatesByEntity.put(upliftRate.Legal_Entity__c , new List<Uplift_Rate__c>());
                }
                upliftRatesByEntity.get(upliftRate.Legal_Entity__c).add(upliftRate);
            }
            
            if(sendEmail) logs.add('*** , upliftRatesByEntity: '+upliftRatesByEntity);
            system.debug('*** Batch_Contract_Uplift >> upliftRatesByEntity: '+upliftRatesByEntity);

        }catch(Exception exc){
            if(sendEmail) logs.add('An exception is thrown while getting UpliftRates : , '+exc.getMessage());
            system.debug('An exception is thrown: '+exc.getMessage());
        }
        
        for(Contract contract : contracts){
            try{
                //1. Calculate actual & previous rate to apply
                actualRateToApply = null;
                previousRateToApply = null;
                rateToApply = null; 

                if(rateByEntityAndFrequence.containsKey(contract.Legal_Entity__c+';'+contract.Legal_Entity__r.Update_Rate_Frequency__c )){
                    actualRateToApply = rateByEntityAndFrequence.get(contract.Legal_Entity__c+';'+contract.Legal_Entity__r.Update_Rate_Frequency__c)[0];
                    previousRateToApply = rateByEntityAndFrequence.get(contract.Legal_Entity__c+';'+contract.Legal_Entity__r.Update_Rate_Frequency__c)[1];
                }
                else{
                    if(upliftRatesByEntity.get(contract.Legal_Entity__c) != null){
                        for(Uplift_Rate__c upliftRate : upliftRatesByEntity.get(contract.Legal_Entity__c)){
                            if(upliftRate.Index_Year__c == years[0] && upliftRate.Index_Period__c == periods.get(contract.Legal_Entity__r.Update_Rate_Frequency__c)){
                                actualRateToApply = upliftRate.Index__c;
                            }
                            else if(upliftRate.Index_Year__c == years[1] && upliftRate.Index_Period__c == periods.get(contract.Legal_Entity__r.Update_Rate_Frequency__c)){
                                previousRateToApply = upliftRate.Index__c;
                            }
                        }
                    }
                }
                
                if(sendEmail) logs.add(contract.Id + ' , previousRateToApply: '+previousRateToApply);
                if(sendEmail) logs.add(contract.Id + ' , actualRateToApply: '+actualRateToApply);

                system.debug('*** Batch_Contract_Uplift >> previousRateToApply: '+previousRateToApply);
                system.debug('*** Batch_Contract_Uplift >> actualRateToApply: '+actualRateToApply);

                if(previousRateToApply != null && actualRateToApply != null && previousRateToApply < actualRateToApply){
                    //2. Calculate rate to apply
                    rateToApply = actualRateToApply / previousRateToApply;
                    if(contract.Uplift_Mode__c == 'Pourcentage fixe négocié'){
                        rateToApply = rateToApply < contract.Negociated_Rate__c ? rateToApply : contract.Negociated_Rate__c;
                    }
                    else if(contract.Uplift_Mode__c == 'Pourcentage de l\'indice négocié'){
                        rateToApply = rateToApply * contract.Negociated_Rate__c;
                    }

                    logs.add(contract.Id + ' , rateToApply: '+rateToApply);
                    system.debug('*** Batch_Contract_Uplift >> rateToApply: '+rateToApply);

                    RTAByOrder.put(contract.SBQQ__Order__c , rateToApply);
                }
            }
            catch(Exception exc){
                if(sendEmail) logs.add('An exception is thrown while calculating uplift for '+ contract.Id +': , '+exc.getMessage());
                system.debug('An exception is thrown while calculating uplift for '+ contract.Id +': , '+exc.getMessage()); 
            }    
        } 
        
        try{
            Map<Id , Decimal> priceTiersByOrderItem = new Map<Id , Decimal>();
            
            Map<Id , OrderItem> orderProducts = new Map<Id , OrderItem> ([Select Id From OrderItem Where OrderId In :RTAByOrder.keySet() And Uplift_Eligible__c = true]);
			
            List<blng__UsageSummary__c> usageSummaries = [Select Id , blng__AppliedUnitPrice__c , blng__UnitPrice__c , blng__OrderProduct__r.OrderId From blng__UsageSummary__c Where blng__OrderProduct__c In :orderProducts.keySet() And blng__SummaryStartDate__c > :todayDate];
            
			List<SBQQ__PriceTier__c> priceTiers = [Select Id , SBQQ__PriceSchedule__r.SBQQ__OrderProduct__c , SBQQ__Price__c from SBQQ__PriceTier__c where SBQQ__PriceSchedule__r.SBQQ__OrderProduct__c IN :orderProducts.keySet()];
			
            for(SBQQ__PriceTier__c priceTier : priceTiers){
                if(!priceTiersByOrderItem.containsKey(priceTier.SBQQ__PriceSchedule__r.SBQQ__OrderProduct__c) && priceTier.SBQQ__Price__c != null && priceTier.SBQQ__Price__c != 0)
                	priceTiersByOrderItem.put(priceTier.SBQQ__PriceSchedule__r.SBQQ__OrderProduct__c , priceTier.SBQQ__Price__c);
            }
            
            for(blng__UsageSummary__c usageSummary : usageSummaries){
                if(priceTiersByOrderItem.containsKey(usageSummary.blng__OrderProduct__c)){
                    usageSummary.blng__AppliedUnitPrice__c = (usageSummary.blng__AppliedUnitPrice__c == null || usageSummary.blng__AppliedUnitPrice__c == 0) ? priceTiersByOrderItem.get(usageSummary.blng__OrderProduct__c) * RTAByOrder.get(usageSummary.blng__OrderProduct__r.OrderId) : usageSummary.blng__AppliedUnitPrice__c * RTAByOrder.get(usageSummary.blng__OrderProduct__r.OrderId); 
                }
                else{
                    usageSummary.blng__AppliedUnitPrice__c = (usageSummary.blng__AppliedUnitPrice__c == null || usageSummary.blng__AppliedUnitPrice__c == 0) ? usageSummary.blng__UnitPrice__c * RTAByOrder.get(usageSummary.blng__OrderProduct__r.OrderId) : usageSummary.blng__AppliedUnitPrice__c * RTAByOrder.get(usageSummary.blng__OrderProduct__r.OrderId);
                }
            }
            update usageSummaries;
            
            if(sendEmail) logs.add(usageSummaries.size() +' usageSummaries are updated');            
            system.debug(usageSummaries.size() +' usageSummaries are updated');
            
            Date nextDate; 
            for(Contract contract : contracts){
                nextDate = contract.Legal_Entity__r.Update_Rate_Frequency__c == 'Mensuelle' ? contract.Next_Date_Uplift__c.addMonths(1) : ( contract.Legal_Entity__r.Update_Rate_Frequency__c == 'Trimestrielle' ? contract.Next_Date_Uplift__c.addMonths(3) : contract.Next_Date_Uplift__c.addYears(1));
                contract.Next_Date_Uplift__c = nextDate;
            }
            update contracts;
            
            if(sendEmail) logs.add(contracts.size() +' contracts are updated');            
            system.debug(contracts.size() +' contracts are updated');

        }
        catch(Exception exc){
            if(sendEmail) logs.add('An exception is thrown while updating Contracts / UsageSummaries: , '+exc.getMessage());
            system.debug('An exception is thrown while updating Contracts / UsageSummaries: , '+exc.getMessage());
        }
              
    }

    global void finish(Database.BatchableContext bc){
        AsyncApexJob a = [SELECT id, ApexClassId,
                       JobItemsProcessed, TotalJobItems,
                       NumberOfErrors, CreatedBy.Email
                       FROM AsyncApexJob
                       WHERE id = :bc.getJobId()];
        if(sendEmail) {
            String body = 'Your batch job '
             + 'Batch_Contract_Uplift '
             + 'has finished. \n' 
             + 'Here is your logs ';
            
            // Creating the CSV file
            String finalstr = 'Context , Log \n';
            String subject = 'Batch_Contract_Uplift - Logs';
            String attName = 'Batch_Contract_Uplift Logs.csv';
            for(String line  : logs){
                finalstr = finalstr +line+'\n';
            } 
 
            // Define the email
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage(); 
            
            // Create the email attachment    
            Messaging.EmailFileAttachment efa = new Messaging.EmailFileAttachment();
            efa.setFileName(attName);
            efa.setBody(Blob.valueOf(finalstr));
            
            // Sets the paramaters of the email
            email.setSubject( subject );
            //email.setToAddresses( new String[] {a.CreatedBy.Email} );
            email.setToAddresses( new String[] {'meryem.ahmada@nbs-consulting.net'} );
            email.setPlainTextBody( body );
            email.setFileAttachments(new Messaging.EmailFileAttachment[] {efa});
 
            // Sends the email
            Messaging.SendEmailResult [] r = 
            Messaging.sendEmail(new Messaging.SingleEmailMessage[] {email});
        }
        
    }

    
}