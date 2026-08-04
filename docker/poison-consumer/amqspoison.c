/********************************************************************/
/*                                                                  */
/* Program name: AMQSPOISON                                         */
/*                                                                  */
/* Description: Simulates a consumer that can never process a       */
/*              message successfully, and implements the            */
/*              application-side half of IBM MQ's poison-message    */
/*              handling convention.                                */
/*                                                                  */
/* IMPORTANT: the queue manager does NOT reroute backed-out          */
/* messages to BOQNAME by itself. BOTHRESH/BOQNAME are just queue    */
/* attributes the queue manager exposes for a consuming              */
/* application to read (via MQINQ) and act on. It is this            */
/* program's job to notice that MQMD.BackoutCount has reached the    */
/* queue's BOTHRESH and, instead of backing out again, explicitly    */
/* MQPUT the message onto BOQNAME (wrapped in an MQDLH, the same     */
/* header format the DEV.DEAD.LETTER.QUEUE convention and the        */
/* amqsdlq sample expect) and MQCOMMIT - atomically removing it       */
/* from the source queue and placing it on the dead-letter queue     */
/* in one unit of work.                                              */
/*                                                                  */
/* Modeled on the amqsget0.c / amqsput0.c samples shipped with IBM   */
/* MQ - see /opt/mqm/samp/ in the moov-mq image.                     */
/*                                                                  */
/* Program logic:                                                    */
/*      MQCONNX to the queue manager                                 */
/*      MQOPEN the source queue for INPUT                            */
/*      MQINQ the source queue's BOTHRESH and BOQNAME                */
/*      repeat up to <max-attempts> times:                           */
/*      .  MQGET the next message under syncpoint                    */
/*      .  if BackoutCount < BOTHRESH: MQBACK (simulate a failed      */
/*         processing attempt; message stays for the next get)       */
/*      .  else: MQOPEN BOQNAME, MQPUT a copy wrapped in an MQDLH,    */
/*         MQCOMMIT (atomically move it), and stop                   */
/*      MQCLOSE, MQDISC                                              */
/*                                                                  */
/* Usage:                                                            */
/*      amqspoisonc <queue> <qmgr> [<max-attempts>]                  */
/*                                                                  */
/********************************************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <cmqc.h>

int main(int argc, char **argv)
{
  MQOD    od    = {MQOD_DEFAULT};
  MQOD    dlqOd = {MQOD_DEFAULT};
  MQMD    md    = {MQMD_DEFAULT};
  MQMD    dlqMd = {MQMD_DEFAULT};
  MQGMO   gmo   = {MQGMO_DEFAULT};
  MQPMO   pmo   = {MQPMO_DEFAULT};
  MQCNO   cno   = {MQCNO_DEFAULT};
  MQDLH   dlh   = {MQDLH_DEFAULT};

  MQHCONN Hcon;
  MQHOBJ  Hobj;
  MQHOBJ  HobjDlq;
  MQLONG  OpenCode;
  MQLONG  CompCode;
  MQLONG  Reason;
  MQLONG  CReason;
  MQBYTE  buffer[65536];
  MQBYTE  dlqBuffer[sizeof(MQDLH) + sizeof(buffer)];
  MQLONG  buflen;
  MQLONG  messlen;
  char    QMName[50];
  int     maxAttempts;
  int     attempt;

  /* Inquire selectors/values for MQINQ */
  MQLONG  selectors[1];
  MQLONG  intAttrs[1];
  MQLONG  charAttrLength;
  MQCHAR  boqName[MQ_Q_NAME_LENGTH + 1];
  MQLONG  bothresh;

  time_t  now;
  struct tm *nowTm;

  printf("Sample AMQSPOISON start\n");
  if (argc < 2)
  {
    printf("Required parameter missing - queue name\n");
    exit(99);
  }

  strncpy(od.ObjectName, argv[1], MQ_Q_NAME_LENGTH);
  QMName[0] = 0;
  if (argc > 2)
    strncpy(QMName, argv[2], MQ_Q_MGR_NAME_LENGTH);

  maxAttempts = 5;
  if (argc > 3)
    maxAttempts = atoi(argv[3]);

  MQCONNX(QMName, &cno, &Hcon, &CompCode, &CReason);
  if (CompCode == MQCC_FAILED)
  {
    printf("MQCONNX ended with reason code %d\n", CReason);
    exit((int)CReason);
  }

  MQOPEN(Hcon, &od,
         MQOO_INPUT_AS_Q_DEF | MQOO_INQUIRE | MQOO_FAIL_IF_QUIESCING,
         &Hobj, &OpenCode, &Reason);

  if (Reason != MQRC_NONE)
    printf("MQOPEN ended with reason code %d\n", Reason);

  if (OpenCode == MQCC_FAILED)
  {
    printf("unable to open queue for input\n");
    exit((int)Reason);
  }

  /********************************************************************/
  /* Read BOTHRESH/BOQNAME off the queue itself rather than            */
  /* hard-coding them, so this program works against whatever a queue  */
  /* was actually configured with.                                     */
  /********************************************************************/
  selectors[0] = MQIA_BACKOUT_THRESHOLD;
  MQINQ(Hcon, Hobj, 1, selectors, 1, intAttrs, 0, NULL, &CompCode, &Reason);
  bothresh = (CompCode == MQCC_FAILED) ? 0 : intAttrs[0];

  selectors[0] = MQCA_BACKOUT_REQ_Q_NAME;
  memset(boqName, ' ', sizeof(boqName) - 1);
  boqName[sizeof(boqName) - 1] = '\0';
  MQINQ(Hcon, Hobj, 1, selectors, 0, NULL, MQ_Q_NAME_LENGTH, boqName,
        &CompCode, &Reason);
  if (CompCode == MQCC_FAILED)
    boqName[0] = '\0';

  printf("source queue BOTHRESH=%d BOQNAME='%.48s'\n", bothresh, boqName);

  gmo.Options = MQGMO_WAIT | MQGMO_SYNCPOINT | MQGMO_CONVERT;
  gmo.WaitInterval = 5000;

  for (attempt = 1; attempt <= maxAttempts; attempt++)
  {
    memcpy(md.MsgId, MQMI_NONE, sizeof(md.MsgId));
    memcpy(md.CorrelId, MQCI_NONE, sizeof(md.CorrelId));
    md.Encoding = MQENC_NATIVE;
    md.CodedCharSetId = MQCCSI_Q_MGR;
    buflen = sizeof(buffer) - 1;

    MQGET(Hcon, Hobj, &md, &gmo, buflen, buffer, &messlen,
          &CompCode, &Reason);

    if (Reason == MQRC_NO_MSG_AVAILABLE)
    {
      printf("attempt %d: no message available\n", attempt);
      break;
    }

    if (CompCode == MQCC_FAILED)
    {
      printf("attempt %d: MQGET ended with reason code %d\n", attempt, Reason);
      break;
    }

    printf("attempt %d: got message, BackoutCount=%d (BOTHRESH=%d)\n",
           attempt, md.BackoutCount, bothresh);

    if (bothresh > 0 && boqName[0] != '\0' && md.BackoutCount >= bothresh)
    {
      printf("attempt %d: BackoutCount has reached BOTHRESH - rerouting "
             "to '%.48s' instead of processing it again\n",
             attempt, boqName);

      strncpy(dlqOd.ObjectName, boqName, MQ_Q_NAME_LENGTH);
      MQOPEN(Hcon, &dlqOd, MQOO_OUTPUT | MQOO_FAIL_IF_QUIESCING,
             &HobjDlq, &OpenCode, &Reason);
      if (OpenCode == MQCC_FAILED)
      {
        printf("unable to open backout queue '%.48s' - reason code %d\n",
               boqName, Reason);
        MQBACK(Hcon, &CompCode, &Reason);
        break;
      }

      /* Build the dead-letter header. DestQName/DestQMgrName record   */
      /* where the message actually came from, which is what          */
      /* amqsdlqc (and anyone else reading this queue) needs to know   */
      /* to make sense of an otherwise-anonymous message.              */
      dlh.Reason = MQRC_BACKOUT_THRESHOLD_REACHED;
      strncpy(dlh.DestQName, od.ObjectName, MQ_Q_NAME_LENGTH);
      strncpy(dlh.DestQMgrName, QMName, MQ_Q_MGR_NAME_LENGTH);
      dlh.Encoding = md.Encoding;
      dlh.CodedCharSetId = md.CodedCharSetId;
      memcpy(dlh.Format, md.Format, sizeof(dlh.Format));

      now = time(NULL);
      nowTm = gmtime(&now);
      if (nowTm != NULL)
      {
        strftime(dlh.PutDate, sizeof(dlh.PutDate) + 1, "%Y%m%d", nowTm);
        strftime(dlh.PutTime, sizeof(dlh.PutTime) + 1, "%H%M%S00", nowTm);
      }

      memcpy(dlqBuffer, &dlh, sizeof(MQDLH));
      memcpy(dlqBuffer + sizeof(MQDLH), buffer, (size_t)messlen);

      memcpy(dlqMd.Format, MQFMT_DEAD_LETTER_HEADER,
             (size_t)MQ_FORMAT_LENGTH);
      dlqMd.Persistence = md.Persistence;
      pmo.Options = MQPMO_SYNCPOINT | MQPMO_FAIL_IF_QUIESCING;

      MQPUT(Hcon, HobjDlq, &dlqMd, &pmo, sizeof(MQDLH) + (size_t)messlen,
            dlqBuffer, &CompCode, &Reason);
      if (Reason != MQRC_NONE)
        printf("MQPUT to backout queue ended with reason code %d\n", Reason);

      MQCLOSE(Hcon, &HobjDlq, MQCO_NONE, &CompCode, &Reason);

      if (CompCode == MQCC_FAILED)
      {
        printf("MQPUT to backout queue failed - backing out instead\n");
        MQBACK(Hcon, &CompCode, &Reason);
      }
      else
      {
        MQCMIT(Hcon, &CompCode, &Reason);
        if (Reason != MQRC_NONE)
          printf("MQCMIT ended with reason code %d\n", Reason);
        else
          printf("attempt %d: committed - message moved to '%.48s'\n",
                 attempt, boqName);
      }
      break;
    }

    /* Not at threshold yet - simulate "processing failed" and roll   */
    /* the get back, leaving the message for the next attempt with     */
    /* its BackoutCount incremented.                                   */
    MQBACK(Hcon, &CompCode, &Reason);
    if (Reason != MQRC_NONE)
      printf("attempt %d: MQBACK ended with reason code %d\n", attempt, Reason);
  }

  MQCLOSE(Hcon, &Hobj, MQCO_NONE, &CompCode, &Reason);
  if (Reason != MQRC_NONE)
    printf("MQCLOSE ended with reason code %d\n", Reason);

  MQDISC(&Hcon, &CompCode, &Reason);
  if (Reason != MQRC_NONE)
    printf("MQDISC ended with reason code %d\n", Reason);

  printf("Sample AMQSPOISON end\n");
  return (0);
}
