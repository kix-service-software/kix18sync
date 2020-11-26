-- mysql -p -e "CREATE USER 'SomeDBUser'@'localhost' IDENTIFIED BY 'PASSWORD';"
-- mysql -p -e "CREATE DATABASE MyCRMDB CHARACTER SET utf8 COLLATE utf8_general_ci;"
-- mysql -p -e "GRANT ALL PRIVILEGES ON MyCRMDB.* TO 'SomeDBUser'@'localhost';"
-- mysql -p -e "FLUSH PRIVILEGES;"
-- mysql -hlocalhost -uSomeDBUser -pPASSWORD MyCRMDB < ./sample/sampledb.sql

DROP TABLE IF EXISTS some_org;
DROP TABLE IF EXISTS some_customer_user;

-- sample org source...
CREATE TABLE some_org
( id           INT(11) NOT NULL AUTO_INCREMENT,
  customer_id  VARCHAR(50) NOT NULL,
  name_org     VARCHAR(50),
  comments     VARCHAR(50),
  addr_street  VARCHAR(50),
  addr_city    VARCHAR(50),
  addr_zip     VARCHAR(50),
  addr_country VARCHAR(50),
  url          VARCHAR(50),
  CONSTRAINT so_id_pk PRIMARY KEY (id)
);

INSERT INTO some_org SET
  customer_id  = 'ACME',
  name_org     = 'A.C.M.E. Ltd',
  comments     = 'A sample entry.',
  addr_street  = '221 Murray Rd.',
  addr_city    = 'Newark, DE',
  addr_zip     = '19711',
  addr_country = 'United States',
  url          = 'https://www.some.url';
INSERT INTO some_org SET
  customer_id  = 'SECRET',
  name_org     = 'Secret Company Ltd',
  comments     = 'Another sample entry.',
  addr_street  = '221b Baker Street',
  addr_city    = 'London',
  addr_zip     = 'W1U 8ED',
  addr_country = 'United Kingdom',
  url          = 'https://www.someother.url';

-- sample contact source...
CREATE TABLE some_customer_user
( id           INT(11) NOT NULL AUTO_INCREMENT,
  email0       VARCHAR(50) NOT NULL,
  first_name   VARCHAR(50) NOT NULL,
  last_name    VARCHAR(50) NOT NULL,
  title        VARCHAR(50),
  addr_street  VARCHAR(50),
  addr_city    VARCHAR(50),
  addr_zip     VARCHAR(50),
  addr_country VARCHAR(50),
  phone1       VARCHAR(50),
  phone2       VARCHAR(50),
  fax1         VARCHAR(50),
  businessfnct VARCHAR(50),
  customer_id  VARCHAR(50) NOT NULL, -- your primary org-number
  CONSTRAINT so_id_pk PRIMARY KEY (id)
);

--
INSERT INTO some_customer_user SET
  email0       = 'John.D@some.url',
  first_name   = 'John',
  last_name    = 'Doe',
  title        = 'Mr.',
  addr_street  = '123 Sample Street',
  addr_city    = 'Springfield',
  addr_zip     = '12345',
  addr_country = '',
  phone1       = '+1 555 123 456',
  phone2       = '+1 555 123 457',
  fax1         = '+1 555 666 999 666',
  businessfnct = 'Product Owner',
  customer_id  = 'ACME';
INSERT INTO some_customer_user SET
  email0       = 'Lisa.L@some.url',
  first_name   = 'Lisa',
  last_name    = 'Lomax',
  title        = 'Mrs.',
  addr_street  = '',
  addr_city    = '',
  addr_zip     = '',
  addr_country = '',
  phone1       = '+1 555 123 456',
  phone2       = '+1 555 123 457',
  fax1         = '+1 555 666 999 666',
  businessfnct = 'Marketing',
  customer_id  = 'ACME';
INSERT INTO some_customer_user SET
  email0       = 'Max.P@someother.url',
  first_name   = 'Max',
  last_name    = 'Power',
  title        = 'Mr.',
  addr_street  = '',
  addr_city    = '',
  addr_zip     = '',
  addr_country = '',
  phone1       = '+1 555 333 456',
  phone2       = '+1 555 333 457',
  fax1         = '+1 555 333 999 666',
  businessfnct = 'dunno',
  customer_id  = 'SECRET';
INSERT INTO some_customer_user SET
  email0       = 'Max.M@someother.url',
  first_name   = 'Max',
  last_name    = 'Master',
  title        = 'Mr.',
  addr_street  = '',
  addr_city    = '',
  addr_zip     = '',
  addr_country = '',
  phone1       = '+1 555 333 456',
  phone2       = '+1 555 333 457',
  fax1         = '+1 555 333 999 666',
  businessfnct = 'M, just M',
  customer_id  = 'SECRET';
