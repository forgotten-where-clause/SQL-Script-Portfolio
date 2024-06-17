/* AccuClue Script 
I wrote this script in 2018 to assist with troubleshooting changes made by users at an old job. 

DB and table names have been changed for security reasons. 

This script attempts to determine where a change occurred in the system by pulling information from the Queue table,
identifying sets of changes that were queued up, and then finding out what xStationID was not queued to, giving
indicating the change was likely pushed from that station. 


It starts by taking a Recipient LastName and part of an Order Description and finding all queued records matching those. 
It then groups the queued records by minute to establish when individual changes were queued to a group of machines.
Lastly it uses a while loop to iterate through the records and identify which stationID is missing, screening out stations without
routes and the local machinename along the way. */


/* VARIABLE DECLARATIONS */
use genericEmarDBname

SET NOCOUNT ON

DECLARE @Surname VARCHAR(36) /* recipient last name */
DECLARE @DrugName VARCHAR(36) /* all or part of drug name */
DECLARE @ResultCount INT /* number of queued record sets */
DECLARE @counter INT /* counter for loop */
DECLARE @currentOrder uniqueidentifier /* holder for orderID in loop*/
DECLARE @currentDateAdd smalldatetime /* holder for timestamp in loop */
DECLARE @StationNotQueued nvarchar(50) /* holder for xstationID in loop */
DECLARE @currentSurname VARCHAR(36) /* holder for recipient last name in loop*/
DECLARE @currentFirstName VARCHAR(36) /* holder for first name in loop */
DECLARE @currentDrugName VARCHAR(36) /* holder for all or part of drug name in loop*/
DECLARE @AEDholder char(1) /*holder for AED status in the loop */

SET @counter = 1

DECLARE @simpleQueue TABLE (
	Station varchar(30) NOT NULL,
	StationID uniqueidentifier NOT NULL,
	AED char(1) NULL,
	FirstName varchar(30) NOT NULL,
	LastName varchar(30) NOT NULL,
	OrderDescription varchar (50) NOT NULL,
	OrderID uniqueidentifier NOT NULL,
	RXNumber nvarchar(15) NOT NULL,
	SourceTable nvarchar(100) NOT NULL,
	DateAdded smalldatetime NULL,
	DateProcessed smalldatetime NULL

	);

DECLARE @results TABLE (
	ID int NOT NULL IDENTITY(1,1),
	RecordID uniqueidentifier NOT NULL,
	DateAdded smalldatetime NULL,
	AED char(1) NULL,
	StationsNotQueued nvarchar(50) NULL
	);


DECLARE @finalResults TABLE (
	ID int NOT NULL IDENTITY(1,1),
	FirstName VARCHAR(36) NOT NULL,
	LastName VARCHAR(36) NOT NULL,
	DrugName VARCHAR(50) NOT NULL,	
	RecordID uniqueidentifier NOT NULL,
	AED char(1) NULL,
	DateAdded smalldatetime NULL,
	StationsNotQueued nvarchar(50) NULL
	);

/* EDIT THESE VARIABLES TO LOOKUP DIFFERENT RECORDS */

SET @Surname = 'Doe' 
SET @DrugName = 'vitamin'


/* Step 1 - collect all pertinent info and combine into a temp table called simpleQueue */
INSERT INTO @simpleQueue 
select s.xStationID, q.StationID, q.AED, r.FirstName, r.LastName, o.OrderDescription, o.OrderID, o.xOrderID,
 q.TableName, q.DateAdded, q.DateProcessed from Queue q
INNER JOIN Station s on s.StationID = q.StationID
INNER JOIN Orders o on o.OrderID = q.UniqueID
INNER JOIN Recipient r on r.RecipientID = o.RecipientID
where o.OrderDescription LIKE '%'+ @DrugName + '%'
and o.RecipientID in (
	select RecipientID from Recipient where LastName = @Surname) 
and DateAdded > DATEADD( DAY, -10, GETDATE() ) -- select within the last ten days - may edit here to reduce window if too many results --
order by DateAdded DESC, UniqueID


/*select * from @simpleQueue - uncomment this line to print the results */

/*Step 2 - identify groups of results by timestamp */
insert into @results(RecordID, DateAdded, AED)
select distinct OrderID, DateAdded, AED
from @simpleQueue
group by orderID, DateAdded, AED
order by DateAdded DESC, OrderID, AED DESC;

set @resultcount = (select count(*) from @results)


/* Step 3 - loop through groups, find missing stationIDs, and write to finalResults table */
WHILE @counter < (@resultCount + 1) 
BEGIN
	set @currentOrder = (select RecordID from @results where ID = @counter)
	set @currentDateAdd = (select DateAdded from @results where ID = @counter)
	set @currentSurname = (select top 1 LastName from @simpleQueue where OrderID = @currentOrder)
	set @currentFirstName = (select top 1 FirstName from @simpleQueue where OrderID = @currentOrder)
	set @currentDrugName = (select top 1 OrderDescription from @simpleQueue where OrderID = @currentOrder)
	set @AEDholder = (select AED from @results where ID = @counter) 
	set @StationNotQueued = (
	select xStationID from Station where StationID NOT IN 
		(select StationID from @simpleQueue where OrderID = @currentOrder and DateAdded = @currentDateAdd)
		AND NOT StationID in (select StationID from MachineMap where MachineName = 'AL-7W-FS') /* filter out local station, hard coded for test, would be HOST_NAME() */
		AND xStationID in (select MachineName from Route)  /* filter out active stations */
		);
	

insert into @finalResults (FirstName, LastName, DrugName, RecordID, AED, DateAdded, StationsNotQueued) 
	values (@currentFirstName, @currentSurname, @currentDrugName, @currentOrder, @AEDholder, @currentDateAdd, @StationNotQueued)
update @finalResults SET StationsNotQueued = 'Facility Server' WHERE StationsNotQueued IS NULL /* remove nulls for FS changes */

set @counter = @counter + 1

/* print @StationNotQueued */
END

/* output results to screen */
select * from @finalResults


/* Part 4 - Check Changelogs to see who is responsible and generate messages */
/* declare new variables */
DECLARE @printMessage nvarchar(MAX)
DECLARE @timestamp datetime
DECLARE @timeMessage varchar(30)
DECLARE @guiltyParty varchar(30)
DECLARE @crimeScene varchar(30)
DECLARE @reportCounter INT
DECLARE @RecordID varchar(36)
DECLARE @changeType char(1)
DECLARE @residentLastName varchar(36)
DECLARE @residentFirstName varchar(36)
DECLARE @finalDrugName varchar(36)

SET @reportCounter = 1

/* loop over finalResults table and get relevant info for printed message */
WHILE @reportCounter < (select count(*) from @finalResults)
BEGIN

SET @changeType = (select AED from @finalResults where ID = @reportCounter)
SET @timestamp = (select DateAdded from @finalResults where ID = @reportCounter)
SET @crimeScene = (select StationsNotQueued from @finalResults where ID = @reportCounter)
SET @residentFirstName = (select FirstName from @finalResults where ID = @reportCounter)
SET @residentLastName = (select LastName from @finalResults where ID = @reportCounter)
SET @finalDrugName = (select DrugName from @finalResults where ID = @reportCounter)
SET @RecordID = (select RecordID from @finalResults where ID = @reportCounter)
SET @RecordID = cast(@RecordID AS varchar(36))
/*print @timestamp */
/*edit cases */
IF @changeType = 'E'
	BEGIN
	/* If there is a Changelog entry close in time for OrderChangedBy field, get the username */
	IF (select count(*) from ChangeLog c 
		where c.FieldName = 'OrderChangedBy' AND c.AddDate BETWEEN 
			(DATEADD(MINUTE, -1, @timestamp)) AND (DATEADD (MINUTE, 1, @timestamp))) <> 0 
	
		BEGIN
		/*print 'user detected' */
		SET @guiltyParty = (select c.NewValue from Changelog c
			where c.FieldName = 'OrderChangedBy' AND c.AddDate BETWEEN 
				(DATEADD(MINUTE, -1, @timestamp)) AND (DATEADD (MINUTE, 1, @timestamp))) 
		END
		/* if no OrderChangedBy Changelog entry, set to Unknown User */
		ELSE BEGIN SET @guiltyParty = 'Unknown User' END
	
	SET @timeMessage = cast(@timestamp as varchar(30)) /* convert type for printing */
	SET @printMessage =  'At ' + @timeMessage + ' ' + @guiltyParty + ' made changes to ' + @RecordID + ' (' + @finalDrugName + ' for '  
		+ @residentFirstName + ' ' + @residentLastName + ') probably originating from ' + @crimeScene + '.' 
	END
ELSE IF @changeType = 'A' /* add order cases - pull adduserID from orders table  */
	BEGIN
	SET @guiltyParty = (select AddUserID from Orders where OrderID = @RecordID)
	SET @timeMessage = cast(@timestamp as varchar(30)) /* convert type for printing */
	SET @printMessage =  'At ' + @timeMessage + ' ' + @guiltyParty + ' added ' + @RecordID + 
		' probably originating from ' + @crimeScene + '.' 
	END

PRINT @printMessage
SET @reportCounter = @reportCounter + 1
END

SET NOCOUNT OFF
