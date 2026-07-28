/****************************************************************************************************************
  SUPPORTING INDEXES
****************************************************************************************************************/

-- Speeds up the RowStart date-range filter
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Person_RowStart' AND object_id = OBJECT_ID('acct.Person')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_Person_RowStart
        ON acct.Person (RowStart)
        INCLUDE (Id, FirstName, LastName, DateOfBirth, RowEnd, EmailAddress);
END
GO

-- Speeds up both AccountPerson lookups (role 1 = child, role 2 = household owner)
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_AccountPerson_PersonId_AccountRoleId' AND object_id = OBJECT_ID('acct.AccountPerson')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountPerson_PersonId_AccountRoleId
        ON acct.AccountPerson (PersonId, AccountRoleId)
        INCLUDE (AccountId);
END
GO

/****************************************************************************************************************
  PROCEDURE: sf.GetChildContactsForFabric
****************************************************************************************************************/

/****** Object:  StoredProcedure [sf].[GetChildContactsForFabric]    Script Date: 7/26/2026 9:51:20 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [sf].[GetChildContactsForFabric]
AS
/********************************************************************************************************************
Creator: Neha Ganatra
Create Date: 13 March 2025
Description: This procedure inserts data in Table 
Sample:  Execute [sf].[GetChildContactsForFabric]
Change History
Modified Date			Modified By			Description
2026-07-28				Optimization pass	Added supporting indexes; removed dead/commented-out debug
										lines. No logic changes. #HouseholdEmail GROUP BY flagged for
										review (see inline note) but not changed.
****************************************************************************************************************/
    SET NOCOUNT ON;
	DECLARE @TodayDateTime DATETIME;
	SET @TodayDateTime = GETDATE();

	DECLARE @CSTHourDiff INT 
	SELECT @CSTHourDiff =  LEFT(current_utc_offset,3)  
	FROM sys.time_zone_info 
	WHERE Name = 'Central Standard Time'

	DECLARE @CSTTime DATETIME
	SELECT @CSTTime= DATEADD ( HOUR, @CSTHourDiff,@TodayDateTime)

	DECLARE @FirstOfCurrentMonth DATETIME, @FirstOfNextMonth DATETIME 
	SELECT @FirstOfCurrentMonth = DATETRUNC(MONTH, @CSTTime)
	SELECT @FirstOfNextMonth  = DATEADD(d, 1, EOMONTH(@CSTTime))

	-- Child contacts (AccountRoleId = 1) created this month
	DROP TABLE IF EXISTS #NewChildContactsCreatedDuringMonth
	SELECT b.AccountId , b.PersonId , a.RowStart , a.RowEnd, a.FirstName,a.LastName ,a.DateOfBirth
	INTO #NewChildContactsCreatedDuringMonth
	FROM acct.Person a 
		INNER JOIN acct.AccountPerson b 
			ON b.PersonId = a.Id
	WHERE (a.[RowStart] >= @FirstOfCurrentMonth  AND a.[RowStart] < @FirstOfNextMonth)
		AND b.AccountRoleId = 1

		-- Household owner (AccountRoleId = 2) + email for each of those accounts
		-- NOTE: GROUP BY has no aggregate and includes PersonId, so this can return more than
		-- one row per account if an account has multiple role-2 contacts (would duplicate child
		-- rows in the final join below). Flagged, not changed.
		DROP TABLE IF EXISTS #HouseholdEmail
		SELECT a.AccountId 
		,EmailAddress = CASE WHEN [dbo].[isValidEmailFormat](c.EmailAddress) = 1 THEN EmailAddress ELSE '' END
		,a.PersonId
		INTO #HouseholdEmail
		FROM acct.AccountPerson a
			INNER JOIN #NewChildContactsCreatedDuringMonth b
				ON b.AccountId = a.AccountId
			INNER JOIN acct.Person c 
				ON c.Id = a.PersonId
		WHERE a.AccountRoleId =2
		GROUP BY a.AccountId ,c.EmailAddress, a.PersonId

	 SELECT AccountId = a.AccountId, 
					PersonId = a.PersonId,
					FirstName = CASE  WHEN a.FirstName LIKE '%/%' THEN
                           REPLACE(a.FirstName, '/', '')
                       WHEN a.FirstName LIKE '%\%' THEN
                           REPLACE(a.FirstName, '\', '')
					WHEN a.FirstName IS NULL THEN 'Customer'
									WHEN a.FirstName = '' THEN 'Customer'
									WHEN LEN(a.FirstName) = 0 THEN 'Customer'
									ELSE a.FirstName END ,
					LastName = CASE  WHEN a.LastName LIKE '%/%' THEN
                          REPLACE(a.LastName, '/', '')
                      WHEN a.LastName LIKE '%\%' THEN
                          REPLACE(a.LastName, '\', '')
					WHEN a.LastName IS NULL THEN 'Customer'
									WHEN a.LastName = '' THEN 'Customer'
									WHEN LEN(a.LastName) = 0 THEN 'Customer'
									ELSE a.LastName END,
					DateOfBirth = CASE WHEN  YEAR(a.DateOfBirth)< 1900 THEN '1/1/1900' ELSE a.DateOfBirth END ,
				
					PersonRowStartDate = a.RowStart,
					[PersonRowEndDate] = a.RowEnd,
					[DataloadCreateDate_CST] = @CSTTime,
					[HouseHoldOwnerPersonId] = b.PersonId,
					[HouseHoldEmail] = b.EmailAddress
			 FROM #NewChildContactsCreatedDuringMonth a
				LEFT JOIN #HouseholdEmail b 
					ON b.AccountId = a.AccountId
   
GO
