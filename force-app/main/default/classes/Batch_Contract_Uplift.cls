global class Batch_Contract_Uplift implements Database.Batchable<sObject>, Database.Stateful,Database.AllowsCallouts{
    
    //To avoid Cumulative Timeout Limitation, this batch must be ran with 3 batch size maximum
    //Map to store calculated rates by Frequence and entity
    Map<String , List<Integer>> rateByEntityAndFrequence;
    List<Integer> years;
    Map<String , String> periods;
    Date todayDate;

    List<String> logs;

    public Batch_Contract_Uplift(){
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
        return Database.getQueryLocator('SELECT Id , Legal_Entity__c , Legal_Entity__r.Update_Rate_Frequency__c , Uplift_Mode__c , Next_Date_Uplift__c , Negociated_Rate__c FROM Contract Where Next_Date_Uplift__c =: todayDate and Uplift_Mode__c != :notEligibile order by Legal_Entity__r.name , contract.Legal_Entity__r.Update_Rate_Frequency__c');
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope){
        
        List<Contract> contracts = (List<Contract>) scope;
        Map<Id , Decimal> quoteAmendedMap = new Map<Id , Decimal>();
         
        Set<String> entities = new Set<String>();
        Map<Id , List<Uplift_Rate__c>>  upliftRatesByEntity = new Map<Id , List<Uplift_Rate__c>>();
        Decimal actualRateToApply;
        Decimal previousRateToApply;
        Decimal rateToApply;
        List<SBQQ__Quote__c> quotes;

        logs.add('*** , Processing...');
        system.debug('*** Batch_Contract_Uplift >> Processing...');

        try{
            //Get UpliftRates By Entities
            for(Contract contract : contracts){
                if(! rateByEntityAndFrequence.containsKey(contract.Legal_Entity__c+';'+contract.Legal_Entity__r.Update_Rate_Frequency__c )){
                    entities.add(contract.Legal_Entity__c);
                }
            }

            for(Uplift_Rate__c upliftRate : [Select Id , Index__c , Index_Year__c , Index_Period__c , Legal_Entity__c From Uplift_Rate__c Where Legal_Entity__c In :entities And Index_Year__c In :years And Index_Period__c In :periods.values() ]){
                if(!upliftRatesByEntity.containskey(upliftRate.Legal_Entity__c)){
                    upliftRatesByEntity.put(upliftRate.Legal_Entity__c , new List<Uplift_Rate__c>());
                }
                upliftRatesByEntity.get(upliftRate.Legal_Entity__c).add(upliftRate);
            }
            
            logs.add('*** , upliftRatesByEntity: '+upliftRatesByEntity);
            system.debug('*** Batch_Contract_Uplift >> upliftRatesByEntity: '+upliftRatesByEntity);

        }catch(Exception exc){
            logs.add('An exception is thrown while getting UpliftRates : , '+exc.getMessage());
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
                    for(Uplift_Rate__c upliftRate : upliftRatesByEntity.get(contract.Legal_Entity__c)){
                        if(upliftRate.Index_Year__c == years[0] && upliftRate.Index_Period__c == periods.get(contract.Legal_Entity__r.Update_Rate_Frequency__c)){
                            actualRateToApply = upliftRate.Index__c;
                        }
                        else if(upliftRate.Index_Year__c == years[1] && upliftRate.Index_Period__c == periods.get(contract.Legal_Entity__r.Update_Rate_Frequency__c)){
                            previousRateToApply = upliftRate.Index__c;
                        }
                    }
                }
                
                logs.add(contract.Id + ' , previousRateToApply: '+previousRateToApply);
                logs.add(contract.Id + ' , actualRateToApply: '+actualRateToApply);

                system.debug('*** Batch_Contract_Uplift >> previousRateToApply: '+previousRateToApply);
                system.debug('*** Batch_Contract_Uplift >> actualRateToApply: '+actualRateToApply);

                if(previousRateToApply < actualRateToApply){
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

                    /*
                    //3. Invoke the ContractAmender API
                    Contract_Amender.AmendmentContext context = new Contract_Amender.AmendmentContext();
                    context.returnOnlyQuoteId = true; 
                    String contextJson = JSON.serialize(context);
                    Contract_Amender amender = new Contract_Amender();
                    Contract_Amender.QuoteModel quote = amender.load(contract.Id, contextJson);
                    quoteAmendedMap.put(quote.Id , rateToApply);

                    logs.add(contract.Id + ' , quoteAmended: '+quote.Id);
                    system.debug('*** Batch_Contract_Uplift >> quoteAmended: '+quote.Id + ' for '+contract.Id);
*/
                }
            }
            catch(Exception exc){
                logs.add('An exception is thrown while amending contract with id '+ contract.Id +': , '+exc.getMessage());
                system.debug('An exception is thrown while amending contract with id '+ contract.Id +': , '+exc.getMessage()); 
            }    
        } 
        
        //try{
            //Update Opps & quoteline & contract
            quotes = new List <SBQQ__Quote__c>();
            List<Opportunity> oppsToUpdate = new List<Opportunity> ();
            List<Contract> contratsToUpdate = new List<Contract> ();
            List<SBQQ__QuoteLine__c> qlisToUpdate = new List<SBQQ__QuoteLine__c> ();

            for(SBQQ__Quote__c quote : [SELECT  Id ,  SBQQ__Opportunity2__c , SBQQ__Opportunity2__r.SBQQ__Ordered__c ,  SBQQ__Opportunity2__r.SBQQ__Contracted__c , SBQQ__MasterContract__r.Next_Date_Uplift__c , SBQQ__MasterContract__r.Legal_Entity__r.Update_Rate_Frequency__c , (select Id from SBQQ__LineItems__r where Uplift_Eligible__c = true) from SBQQ__Quote__c Where Id In :quoteAmendedMap.keySet()]){
                for(SBQQ__QuoteLine__c quoteLine : quote.SBQQ__LineItems__r){
                    system.debug(quoteLine.Id +'>'+ quoteAmendedMap.get(quote.Id));
                    qlisToUpdate.add(new SBQQ__QuoteLine__c(Id= quoteLine.Id , SBQQ__Uplift__c = quoteAmendedMap.get(quote.Id)));
                } 
                //quote.SBQQ__Ordered__c = true;
                //quote.SBQQ__Contracted__c = true;
                quotes.add(quote);
                
                Date nextDate = quote.SBQQ__MasterContract__r.Legal_Entity__r.Update_Rate_Frequency__c == 'Mensuelle' ? quote.SBQQ__MasterContract__r.Next_Date_Uplift__c.addMonths(1) : ( quote.SBQQ__MasterContract__r.Legal_Entity__r.Update_Rate_Frequency__c == 'Trimestrielle' ? quote.SBQQ__MasterContract__r.Next_Date_Uplift__c.addMonths(3) : quote.SBQQ__MasterContract__r.Next_Date_Uplift__c.addYears(1));
                contratsToUpdate.add(new Contract(Id= quote.SBQQ__MasterContract__c , Next_Date_Uplift__c = nextDate)); 
                
                oppsToUpdate.add(new Opportunity(Id= quote.SBQQ__Opportunity2__c , SBQQ__Contracted__c = true , SBQQ__Ordered__c = true ));
            }
            

            update qlisToUpdate;
            update contratsToUpdate;
            update oppsToUpdate;
            logs.add('*** , QLI / Opps / Contracts Updated');  
        /*}
        catch(Exception exc){
            logs.add('An exception is thrown while updating QLI / Opps / Contracts: , '+exc.getMessage());
            system.debug('An exception is thrown while updating QLI / Opps / Contracts: , '+exc.getMessage());
        }*/
              
    }

    global void finish(Database.BatchableContext bc){
        AsyncApexJob a = [SELECT id, ApexClassId,
                       JobItemsProcessed, TotalJobItems,
                       NumberOfErrors, CreatedBy.Email
                       FROM AsyncApexJob
                       WHERE id = :bc.getJobId()];
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