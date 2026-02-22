import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getComments from '@salesforce/apex/OnboardingService.getComments';
import addComment  from '@salesforce/apex/OnboardingService.addComment';

export default class OnboardingComments extends LightningElement {

    @api recordId;

    @track commentText   = '';
    @track isInternal    = false;
    @track isSubmitting  = false;
    @track error;

    wiredResult;

    // ── Wire ─────────────────────────────────────────────────────────────────

    @wire(getComments, { requestId: '$recordId' })
    wiredComments(result) {
        this.wiredResult = result;
        if (result.error) {
            this.error = result.error?.body?.message || 'Failed to load comments.';
        }
    }

    // ── Computed ──────────────────────────────────────────────────────────────

    get isLoading() {
        return !this.wiredResult?.data && !this.wiredResult?.error;
    }

    get isEmpty() {
        return !this.isLoading && !this.error && this.comments.length === 0;
    }

    get comments() {
        if (!this.wiredResult?.data) return [];
        return this.wiredResult.data.map(c => ({
            ...c,
            authorName   : c.CreatedBy?.Name || 'Unknown',
            formattedDate: new Date(c.CreatedDate).toLocaleString(),
            commentClass : c.Is_Internal__c ? 'comment-item c-internal' : 'comment-item'
        }));
    }

    get isSubmitDisabled() {
        return this.isSubmitting || !this.commentText.trim();
    }

    // ── Handlers ──────────────────────────────────────────────────────────────

    handleCommentChange(event) {
        this.commentText = event.target.value;
    }

    handleInternalChange(event) {
        this.isInternal = event.target.checked;
    }

    async handleSubmit() {
        if (!this.commentText.trim()) return;
        this.isSubmitting = true;
        try {
            await addComment({
                requestId   : this.recordId,
                commentText : this.commentText.trim(),
                isInternal  : this.isInternal
            });
            this.commentText = '';
            this.isInternal  = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title  : 'Error',
                message: err?.body?.message || 'Could not save comment.',
                variant: 'error'
            }));
        } finally {
            this.isSubmitting = false;
        }
    }
}
