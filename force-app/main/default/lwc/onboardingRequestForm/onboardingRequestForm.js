import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import createOnboardingRequest from '@salesforce/apex/OnboardingService.createOnboardingRequest';
import getActiveUsers from '@salesforce/apex/OnboardingService.getActiveUsers';

const DEPARTMENTS = [
    { label: 'IT',         value: 'IT',         icon: 'utility:desktop'  },
    { label: 'HR',         value: 'HR',         icon: 'utility:people'   },
    { label: 'Finance',    value: 'Finance',    icon: 'utility:moneybag' },
    { label: 'Sales',      value: 'Sales',      icon: 'utility:chart'    },
    { label: 'Marketing',  value: 'Marketing',  icon: 'utility:announce' },
    { label: 'Operations', value: 'Operations', icon: 'utility:settings' }
];

const AUTO_TASKS = [
    { label: 'IT Setup',     icon: 'utility:desktop'        },
    { label: 'Facilities',   icon: 'utility:home'           },
    { label: 'HR Paperwork', icon: 'utility:file'           },
    { label: 'Training',     icon: 'utility:knowledge_base' }
];

const EMPLOYMENT_TYPES = [
    { label: 'Full-Time', value: 'Full-Time' },
    { label: 'Part-Time', value: 'Part-Time' },
    { label: 'Contract',  value: 'Contract'  },
    { label: 'Intern',    value: 'Intern'    }
];

const EXPERIENCE_OPTIONS = [
    { label: '0–1 Years',  value: '0-1 Years'  },
    { label: '1–3 Years',  value: '1-3 Years'  },
    { label: '3–5 Years',  value: '3-5 Years'  },
    { label: '5–10 Years', value: '5-10 Years' },
    { label: '10+ Years',  value: '10+ Years'  }
];

const LOCATIONS = [
    { label: 'New York',      value: 'New York'      },
    { label: 'San Francisco', value: 'San Francisco' },
    { label: 'London',        value: 'London'        },
    { label: 'Austin',        value: 'Austin'        },
    { label: 'Chicago',       value: 'Chicago'       },
    { label: 'Toronto',       value: 'Toronto'       },
    { label: 'Remote',        value: 'Remote'        }
];

const WORK_MODES = [
    { label: 'On-site', value: 'On-site' },
    { label: 'Hybrid',  value: 'Hybrid'  },
    { label: 'Remote',  value: 'Remote'  }
];

export default class OnboardingRequestForm extends NavigationMixin(LightningElement) {

    // ── Employee Details ──────────────────────────────────────────────────────
    @track employeeName   = '';
    @track jobTitle       = '';
    @track employmentType = '';
    @track experience     = '';

    // ── Contact Information ───────────────────────────────────────────────────
    @track personalEmail  = '';
    @track phone          = '';

    // ── Work Setup ────────────────────────────────────────────────────────────
    @track department     = '';
    @track location       = '';
    @track workMode       = '';
    @track startDate      = '';

    // ── Team & Reporting ──────────────────────────────────────────────────────
    @track reportingManagerId = '';
    @track buddyId            = '';

    // ── UI State ──────────────────────────────────────────────────────────────
    @track isLoading           = false;
    @track errorMessage        = '';
    @track isSuccess           = false;
    @track createdEmployeeName = '';

    _createdRecordId = null;

    @wire(getActiveUsers) wiredUsers;

    // ── Static Options ────────────────────────────────────────────────────────

    get autoTaskList()          { return AUTO_TASKS; }
    get employmentTypeOptions() { return EMPLOYMENT_TYPES; }
    get experienceOptions()     { return EXPERIENCE_OPTIONS; }
    get locationOptions()       { return LOCATIONS; }
    get workModeOptions()       { return WORK_MODES; }

    get userOptions() {
        return this.wiredUsers.data || [];
    }

    get departmentOptions() {
        return DEPARTMENTS.map(d => ({
            ...d,
            tileClass: d.value === this.department ? 'dept-tile dept-selected' : 'dept-tile'
        }));
    }

    get minDate() {
        const d = new Date();
        d.setDate(d.getDate() + 1);
        return d.toISOString().split('T')[0];
    }

    // ── Change Handlers ───────────────────────────────────────────────────────

    handleNameChange(e)           { this.employeeName       = e.target.value;                }
    handleJobTitleChange(e)       { this.jobTitle           = e.target.value;                }
    handleEmploymentTypeChange(e) { this.employmentType     = e.detail.value;                }
    handleExperienceChange(e)     { this.experience         = e.detail.value;                }
    handleEmailChange(e)          { this.personalEmail      = e.target.value;                }
    handlePhoneChange(e)          { this.phone              = e.target.value;                }
    handleDeptSelect(e)           { this.department         = e.currentTarget.dataset.value; }
    handleLocationChange(e)       { this.location           = e.detail.value;                }
    handleWorkModeChange(e)       { this.workMode           = e.detail.value;                }
    handleDateChange(e)           { this.startDate          = e.target.value;                }
    handleManagerChange(e)        { this.reportingManagerId = e.detail.value;                }
    handleBuddyChange(e)          { this.buddyId            = e.detail.value;                }

    // ── Reset ─────────────────────────────────────────────────────────────────

    handleReset() {
        this.employeeName       = '';
        this.jobTitle           = '';
        this.employmentType     = '';
        this.experience         = '';
        this.personalEmail      = '';
        this.phone              = '';
        this.department         = '';
        this.location           = '';
        this.workMode           = '';
        this.startDate          = '';
        this.reportingManagerId = '';
        this.buddyId            = '';
        this.errorMessage       = '';
    }

    handleCreateAnother() {
        this.isSuccess           = false;
        this.errorMessage        = '';
        this._createdRecordId    = null;
        this.createdEmployeeName = '';
        this.handleReset();
    }

    handleViewRecord() {
        if (this._createdRecordId) {
            this[NavigationMixin.Navigate]({
                type       : 'standard__recordPage',
                attributes : { recordId: this._createdRecordId, actionName: 'view' }
            });
        }
    }

    // ── Submit ────────────────────────────────────────────────────────────────

    async handleSubmit() {
        this.errorMessage = '';

        if (!this.employeeName.trim()) {
            this.errorMessage = 'Employee Name is required.';
            return;
        }
        if (!this.jobTitle.trim()) {
            this.errorMessage = 'Job Title is required.';
            return;
        }
        if (!this.department) {
            this.errorMessage = 'Please select a Department.';
            return;
        }
        if (!this.startDate) {
            this.errorMessage = 'Start Date is required.';
            return;
        }

        this.isLoading = true;
        try {
            const recordId = await createOnboardingRequest({
                employeeName      : this.employeeName.trim(),
                startDate         : this.startDate,
                department        : this.department,
                jobTitle          : this.jobTitle.trim(),
                employmentType    : this.employmentType     || null,
                experience        : this.experience         || null,
                personalEmail     : this.personalEmail      || null,
                phone             : this.phone              || null,
                location          : this.location           || null,
                workMode          : this.workMode           || null,
                reportingManagerId: this.reportingManagerId || null,
                buddyId           : this.buddyId            || null
            });
            this._createdRecordId    = recordId;
            this.createdEmployeeName = this.employeeName.trim();
            this.handleReset();
            this.isSuccess = true;
        } catch (error) {
            this.errorMessage = error?.body?.message || 'An unexpected error occurred. Please try again.';
        } finally {
            this.isLoading = false;
        }
    }
}
