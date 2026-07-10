;;; Copyright (c) 2026 Nicholas Vermeulen
;;; SPDX-License-Identifier: AGPL-3.0-or-later

;; ─────────────────────────────────────────────────────────────────────────────
;; loop-questions.lisp — The Loop Question Bank
;;
;; Structure per question:
;;   (make-question id category core-question (list follow-up-1 follow-up-2 ...))
;;
;; Design principles:
;;   - Core questions open a door; follow-ups go through it
;;   - Questions aim for sensory memory first — smell, texture, sound
;;   - Follow-ups move toward "why" — the emotional truth underneath
;;   - No yes/no questions. Every question invites a story.
;; ─────────────────────────────────────────────────────────────────────────────


;; ── Childhood & Roots ─────────────────────────────────────────────────────────

(define q-childhood-001
  (make-question
    "childhood-001"
    "childhood"
    "When you close your eyes and think of the home you grew up in, what's the first thing you notice — a smell, a sound, the way the light came in?"
    (list
      "What happened in that space? What's a moment you can still feel in your body when you picture it?"
      "Was there a corner of that home that was yours — somewhere you'd go when you needed to just be yourself?"
      "What would a stranger never have understood about that place, that you knew in your bones?")))

(define q-childhood-002
  (make-question
    "childhood-002"
    "childhood"
    "Tell me about a person from your childhood — not a parent, someone else — who quietly shaped who you became."
    (list
      "What did they do or say that stayed with you, even if they probably never knew it mattered?"
      "If you could sit across from them right now, what would you want them to know?")))

(define q-childhood-003
  (make-question
    "childhood-003"
    "childhood"
    "What did you believe about the world when you were young that turned out to be true? And what turned out to be completely wrong?"
    (list
      "Where did that belief come from — was it something you were taught, or something you just felt?"
      "When did you first realize the world was more complicated than you'd thought?")))


;; ── Family & Roots ────────────────────────────────────────────────────────────

(define q-family-001
  (make-question
    "family-001"
    "family-and-roots"
    "Every family has an unspoken rule — something everyone knew but nobody ever said out loud. What was yours?"
    (list
      "Did you follow that rule, or did you eventually push against it?"
      "How did that shape the family you built, or chose not to build, later on?")))

(define q-family-002
  (make-question
    "family-002"
    "family-and-roots"
    "Tell me about your parents — not what they did for work or where they were from, but who they were as people. What made them who they were?"
    (list
      "What's something you understand about one of your parents now that you couldn't have understood as a child?"
      "What did you inherit from them — good or hard — that you can see in yourself today?"
      "Is there something you wish you'd said to one of them that you never got to?")))


;; ── Coming of Age ─────────────────────────────────────────────────────────────

(define q-coming-of-age-001
  (make-question
    "coming-of-age-001"
    "coming-of-age"
    "When did you first feel like you were becoming yourself — not who your family needed you to be, but actually you?"
    (list
      "What made that moment possible? Was there a person, a place, a decision?"
      "Were you scared? What did it cost you to step into that?")))

(define q-coming-of-age-002
  (make-question
    "coming-of-age-002"
    "coming-of-age"
    "Tell me about a mistake you made when you were young that you're actually glad you made."
    (list
      "What did you lose because of it? What did you gain?"
      "If a young person you loved was about to make the same mistake, would you stop them?")))


;; ── Love & Relationships ──────────────────────────────────────────────────────

(define q-love-001
  (make-question
    "love-001"
    "love-and-relationships"
    "Tell me about a love that changed you — it doesn't have to be romantic. A love that made you into someone different than you were before."
    (list
      "What did that person see in you that maybe you couldn't see in yourself?"
      "What did loving them teach you about who you are?"
      "Where does that love live in you now?")))

(define q-love-002
  (make-question
    "love-002"
    "love-and-relationships"
    "What's the hardest thing you've ever had to forgive — in someone else, or in yourself?"
    (list
      "Did you ever fully forgive it, or is it something you carry differently now than you used to?"
      "What does forgiveness mean to you? Did your understanding of it change over time?")))


;; ── Work & Purpose ────────────────────────────────────────────────────────────

(define q-work-001
  (make-question
    "work-001"
    "work-and-purpose"
    "When did you feel most alive in your work — the kind of day where time disappeared and you forgot to eat?"
    (list
      "What was it about that work that did that to you?"
      "Did you ever manage to build a life around it, or was it always something you had to steal time for?")))

(define q-work-002
  (make-question
    "work-002"
    "work-and-purpose"
    "What work are you most proud of — not the most recognized or rewarded, but the thing that you know mattered?"
    (list
      "Who benefited from it, even if they never knew your name?"
      "What would you want people to know about why you did it?")))


;; ── Beliefs & Values ──────────────────────────────────────────────────────────

(define q-beliefs-001
  (make-question
    "beliefs-001"
    "beliefs-and-values"
    "What do you believe that most people around you don't — something you've come to on your own, maybe even paid a price for believing?"
    (list
      "When did you first realize you believed that? Was there a moment, or did it arrive slowly?"
      "Has anyone ever challenged you on it in a way that made you reconsider?")))

(define q-beliefs-002
  (make-question
    "beliefs-002"
    "beliefs-and-values"
    "What do you believe happens when we die?"
    (list
      "Has that belief changed over the course of your life? What changed it?"
      "Does it comfort you, or is it something you're still working out?")))


;; ── Hardship & Resilience ─────────────────────────────────────────────────────

(define q-hardship-001
  (make-question
    "hardship-001"
    "hardship-and-resilience"
    "Tell me about a time everything fell apart. Not just hard — the kind of hard where you didn't know if you'd come back from it."
    (list
      "What got you through it? Was it a person, a belief, sheer stubbornness?"
      "Who were you before that, and who were you after? Was something lost, or was something found?"
      "What would you want someone facing that same kind of dark to know?")))

(define q-hardship-002
  (make-question
    "hardship-002"
    "hardship-and-resilience"
    "What's a loss you've carried that most people don't know about?"
    (list
      "How do you carry it now, compared to how you carried it at the beginning?"
      "Did it change what you believe about life, or about yourself?")))


;; ── Joy & Gratitude ───────────────────────────────────────────────────────────

(define q-joy-001
  (make-question
    "joy-001"
    "joy-and-gratitude"
    "What's brought you the most pure, uncomplicated joy in your life — the kind that doesn't need explaining?"
    (list
      "When did you last feel it? Can you put yourself back there for a moment?"
      "Is that kind of joy still available to you now?")))

(define q-joy-002
  (make-question
    "joy-002"
    "joy-and-gratitude"
    "Who in your life are you most grateful for — and have you ever told them?"
    (list
      "What do they give you that nobody else does?"
      "What do you hope they know about what they've meant to you?")))


;; ── Wisdom ────────────────────────────────────────────────────────────────────

(define q-wisdom-001
  (make-question
    "wisdom-001"
    "wisdom"
    "What do you know now that you wish you'd known at twenty-five?"
    (list
      "How did you learn it — through something good, or something hard?"
      "Is it the kind of thing that can be taught, or does it have to be lived?")))

(define q-wisdom-002
  (make-question
    "wisdom-002"
    "wisdom"
    "What advice would you give to someone you love who's standing at a crossroads — not about which path, but about how to walk any path?"
    (list
      "Where does that advice come from in your own life?"
      "Did someone give you something like that when you needed it?")))


;; ── Legacy & Mortality ────────────────────────────────────────────────────────

(define q-legacy-001
  (make-question
    "legacy-001"
    "legacy-and-mortality"
    "When you imagine the people who love you sitting together after you're gone, what do you hope they say about you?"
    (list
      "Not what you hope they remember you doing — what do you hope they say you were like to be around?"
      "Is that who you've been? Or is it still something you're working toward?")))

(define q-legacy-002
  (make-question
    "legacy-002"
    "legacy-and-mortality"
    "What do you want to make sure you've passed on — not possessions, but something less visible. A way of seeing, a value, a story."
    (list
      "To whom? Is there someone specific you're thinking of?"
      "Have you found a way to pass it on yet, or is that still something you're looking for?")))

(define q-legacy-003
  (make-question
    "legacy-003"
    "legacy-and-mortality"
    "If someone who loved you could ask you anything — anything at all — and you had to answer honestly, what do you think they'd ask?"
    (list
      "And what would you tell them?"
      "Is there something you've wanted to say to someone that you haven't found the words for yet?")))


;; ── Load All Questions Into Bank ──────────────────────────────────────────────

(set! QUESTION-BANK
  (list
    q-childhood-001   q-childhood-002   q-childhood-003
    q-family-001      q-family-002
    q-coming-of-age-001 q-coming-of-age-002
    q-love-001        q-love-002
    q-work-001        q-work-002
    q-beliefs-001     q-beliefs-002
    q-hardship-001    q-hardship-002
    q-joy-001         q-joy-002
    q-wisdom-001      q-wisdom-002
    q-legacy-001      q-legacy-002      q-legacy-003))

(print (str "Loop questions loaded: "
            (number->string (length QUESTION-BANK))
            " questions across "
            (number->string (length CATEGORY-ORDER))
            " categories."))
